use rustler::{
    dynamic::TermType,
    env::{OwnedEnv, SavedTerm},
    resource::ResourceArc,
    types::tuple::make_tuple,
    types::ListIterator,
    Encoder, Env as RustlerEnv, Error, MapIterator, NifResult, Term,
};
use std::sync::Mutex;
use std::thread;

use wasmtime::{Instance, Linker, Module, Val, ValType};

use crate::{
    atoms,
    environment::{link_imports, CallbackTokenResource, StoreOrCaller, StoreOrCallerResource},
    functions,
    module::ModuleResource,
    printable_term_type::PrintableTermType,
    store::StoreData,
};

pub struct InstanceResource {
    pub inner: Mutex<Instance>,
}

#[derive(NifTuple)]
pub struct InstanceResourceResponse {
    ok: rustler::Atom,
    resource: ResourceArc<InstanceResource>,
}

// creates a new instance from the given WASM bytes
// expects the following elixir params
//
// * store (StoreResource): the store the module was compiled with
// * module (ModuleResource): the compiled WASM module
// * imports (map): a map defining eventual instance imports, may be empty if there are none.
//   structure: %{namespace_name: %{import_name: {:fn, param_types, result_types, captured_function}}}
#[rustler::nif(name = "instance_new")]
pub fn new(
    store_or_caller_resource: ResourceArc<StoreOrCallerResource>,
    module_resource: ResourceArc<ModuleResource>,
    imports: MapIterator,
) -> NifResult<InstanceResourceResponse> {
    let module = module_resource.inner.lock().map_err(|e| {
        rustler::Error::Term(Box::new(format!(
            "Could not unlock module resource as the mutex was poisoned: {}",
            e
        )))
    })?;
    let store_or_caller: &mut StoreOrCaller =
        &mut *(store_or_caller_resource.inner.lock().map_err(|e| {
            rustler::Error::Term(Box::new(format!(
                "Could not unlock store_or_caller resource as the mutex was poisoned: {}",
                e
            )))
        })?);

    let instance = link_and_create_instance(store_or_caller, &module, imports)?;
    let resource = ResourceArc::new(InstanceResource {
        inner: Mutex::new(instance),
    });
    Ok(InstanceResourceResponse {
        ok: atoms::ok(),
        resource,
    })
}

fn link_and_create_instance(
    store_or_caller: &mut StoreOrCaller,
    module: &Module,
    imports: MapIterator,
) -> Result<Instance, Error> {
    let mut linker = Linker::new(store_or_caller.engine());
    if let Some(_wasi_ctx) = &store_or_caller.data().wasi {
        linker.allow_shadowing(true);
        wasmtime_wasi::add_to_linker(&mut linker, |s: &mut StoreData| s.wasi.as_mut().unwrap())
            .map_err(|err| Error::Term(Box::new(err.to_string())))?;
    }
    link_imports(&mut linker, imports)?;
    linker
        .instantiate(store_or_caller, module)
        .map_err(|err| Error::Term(Box::new(err.to_string())))
}

#[rustler::nif(name = "instance_function_export_exists")]
pub fn function_export_exists(
    store_or_caller_resource: ResourceArc<StoreOrCallerResource>,
    instance_resource: ResourceArc<InstanceResource>,
    function_name: String,
) -> NifResult<bool> {
    let instance: Instance = *(instance_resource.inner.lock().map_err(|e| {
        rustler::Error::Term(Box::new(format!(
            "Could not unlock instance resource as the mutex was poisoned: {}",
            e
        )))
    })?);
    let store_or_caller: &mut StoreOrCaller =
        &mut *(store_or_caller_resource.inner.lock().map_err(|e| {
            rustler::Error::Term(Box::new(format!(
                "Could not unlock instance/store resource as the mutex was poisoned: {}",
                e
            )))
        })?);

    let result = functions::exists(&instance, store_or_caller, &function_name);
    Ok(result)
}

#[rustler::nif(name = "instance_call_exported_function", schedule = "DirtyCpu")]
pub fn call_exported_function<'a>(
    env: rustler::Env<'a>,
    store_or_caller_resource: ResourceArc<StoreOrCallerResource>,
    instance_resource: ResourceArc<InstanceResource>,
    function_name: String,
    params: Term,
    from: Term,
) -> rustler::Atom {
    let pid = env.pid();
    // create erlang environment for the thread
    let mut thread_env = OwnedEnv::new();
    // copy over params into the thread environment
    let function_params = thread_env.save(params);
    let from = thread_env.save(from);

    thread::spawn(move || {
        thread_env.send_and_clear(&pid, |thread_env| {
            execute_function(
                thread_env,
                store_or_caller_resource,
                instance_resource,
                function_name,
                function_params,
                from,
            )
        })
    });

    atoms::ok()
}

fn execute_function(
    thread_env: RustlerEnv,
    store_or_caller_resource: ResourceArc<StoreOrCallerResource>,
    instance_resource: ResourceArc<InstanceResource>,
    function_name: String,
    function_params: SavedTerm,
    from: SavedTerm,
) -> Term {
    let from = from
        .load(thread_env)
        .decode::<Term>()
        .unwrap_or_else(|_| "could not load 'from' param".encode(thread_env));
    let given_params = match function_params.load(thread_env).decode::<Vec<Term>>() {
        Ok(vec) => vec,
        Err(_) => return make_error_tuple(&thread_env, "could not load 'function params'", from),
    };
    let instance: Instance = *(instance_resource.inner.lock().unwrap());
    let mut store_or_caller = store_or_caller_resource.inner.lock().unwrap();
    let function_result = functions::find(&instance, &mut store_or_caller, &function_name);
    let function = match function_result {
        Some(func) => func,
        None => {
            return make_error_tuple(
                &thread_env,
                &format!("exported function `{}` not found", function_name),
                from,
            )
        }
    };
    let function_params_result = decode_function_param_terms(
        &function
            .ty(&*store_or_caller)
            .params()
            .collect::<Vec<ValType>>(),
        given_params,
    );
    let function_params = match function_params_result {
        Ok(vec) => map_wasm_values_to_vals(&vec),
        Err(reason) => return make_error_tuple(&thread_env, &reason, from),
    };
    let results_count = function.ty(&*store_or_caller).results().len();
    let mut results = vec![Val::null(); results_count];
    let call_result = function.call(
        &mut *store_or_caller,
        function_params.as_slice(),
        &mut results,
    );
    match call_result {
        Ok(_) => (),
        Err(e) => {
            return make_error_tuple(
                &thread_env,
                &format!("Error during function excecution: `{}`.", e),
                from,
            )
        }
    };
    let mut return_values: Vec<Term> = Vec::with_capacity(results_count);
    for value in results.iter().cloned() {
        return_values.push(match value {
            Val::I32(i) => i.encode(thread_env),
            Val::I64(i) => i.encode(thread_env),
            Val::F32(i) => f32::from_bits(i).encode(thread_env),
            Val::F64(i) => f64::from_bits(i).encode(thread_env),
            // encoding V128 is not yet supported by rustler
            Val::V128(_) => {
                return make_error_tuple(&thread_env, "unable_to_return_v128_type", from)
            }
            Val::FuncRef(_) => {
                return make_error_tuple(&thread_env, "unable_to_return_func_ref_type", from)
            }
            Val::ExternRef(_) => {
                return make_error_tuple(&thread_env, "unable_to_return_extern_ref_type", from)
            }
        })
    }
    make_tuple(
        thread_env,
        &[
            atoms::returned_function_call().encode(thread_env),
            make_tuple(
                thread_env,
                &[
                    atoms::ok().encode(thread_env),
                    return_values.encode(thread_env),
                ],
            ),
            from,
        ],
    )
}

#[derive(Debug, Copy, Clone)]
pub enum WasmValue {
    I32(i32),
    I64(i64),
    F32(f32),
    F64(f64),
}

pub fn decode_function_param_terms(
    params: &[ValType],
    function_param_terms: Vec<Term>,
) -> Result<Vec<WasmValue>, String> {
    if params.len() != function_param_terms.len() {
        return Err(format!(
            "number of params does not match. expected {}, got {}",
            params.len(),
            function_param_terms.len()
        ));
    }

    let mut function_params = Vec::<WasmValue>::with_capacity(params.len());
    for (nth, (param, given_param)) in params
        .iter()
        .zip(function_param_terms.into_iter())
        .enumerate()
    {
        let value = match (param, given_param.get_type()) {
            (ValType::I32, TermType::Number) => match given_param.decode::<i32>() {
                Ok(value) => WasmValue::I32(value),
                Err(_) => {
                    return Err(format!(
                        "Cannot convert argument #{} to a WebAssembly i32 value.",
                        nth + 1
                    ));
                }
            },
            (ValType::I64, TermType::Number) => match given_param.decode::<i64>() {
                Ok(value) => WasmValue::I64(value),
                Err(_) => {
                    return Err(format!(
                        "Cannot convert argument #{} to a WebAssembly i64 value.",
                        nth + 1
                    ));
                }
            },
            (ValType::F32, TermType::Number) => match given_param.decode::<f32>() {
                Ok(value) => {
                    if value.is_finite() {
                        WasmValue::F32(value)
                    } else {
                        return Err(format!(
                            "Cannot convert argument #{} to a WebAssembly f32 value.",
                            nth + 1
                        ));
                    }
                }
                Err(_) => {
                    return Err(format!(
                        "Cannot convert argument #{} to a WebAssembly f32 value.",
                        nth + 1
                    ));
                }
            },
            (ValType::F64, TermType::Number) => match given_param.decode::<f64>() {
                Ok(value) => WasmValue::F64(value),
                Err(_) => {
                    return Err(format!(
                        "Cannot convert argument #{} to a WebAssembly f64 value.",
                        nth + 1
                    ));
                }
            },
            (_, term_type) => {
                return Err(format!(
                    "Cannot convert argument #{} to a WebAssembly value. Given `{:?}`.",
                    nth + 1,
                    PrintableTermType::PrintTerm(term_type)
                ));
            }
        };
        function_params.push(value);
    }
    Ok(function_params)
}

pub fn map_wasm_values_to_vals(values: &[WasmValue]) -> Vec<Val> {
    values
        .iter()
        .map(|value| match value {
            WasmValue::I32(value) => (*value).into(),
            WasmValue::I64(value) => (*value).into(),
            WasmValue::F32(value) => (*value).into(),
            WasmValue::F64(value) => (*value).into(),
        })
        .collect()
}

fn make_error_tuple<'a>(env: &RustlerEnv<'a>, reason: &str, from: Term<'a>) -> Term<'a> {
    make_tuple(
        *env,
        &[
            atoms::returned_function_call().encode(*env),
            env.error_tuple(reason),
            from,
        ],
    )
}

// called from elixir, params
// * callback_token
// * success: :ok | :error
//   indicates whether the call was successful or produced an elixir-error
// * results: [number]
//   return values of the elixir-callback - empty list when success-type is :error
#[rustler::nif(name = "instance_receive_callback_result")]
pub fn receive_callback_result(
    token_resource: ResourceArc<CallbackTokenResource>,
    success: bool,
    result_list: ListIterator,
) -> NifResult<rustler::Atom> {
    let results = if success {
        let return_types = token_resource.token.return_types.clone();
        match decode_function_param_terms(&return_types, result_list.collect()) {
            Ok(v) => v,
            Err(reason) => {
                return Err(Error::Term(Box::new(format!(
                    "could not convert callback result param to expected return signature: {}",
                    reason
                ))));
            }
        }
    } else {
        vec![]
    };

    let mut result = token_resource.token.return_values.lock().unwrap();
    *result = Some((success, results));
    token_resource.token.continue_signal.notify_one();

    Ok(atoms::ok())
}
