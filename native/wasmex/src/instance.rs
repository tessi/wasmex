// Clippy regression in rust 1.80.0
// see: https://github.com/rust-lang/rust-clippy/issues/13170
#![allow(clippy::needless_borrows_for_generic_args)]

use crate::{
    atoms,
    engine::TOKIO_RUNTIME,
    environment::{link_imports, link_modules, CallbackTokenResource},
    functions,
    module::ModuleResource,
    printable_term_type::PrintableTermType,
    store::{StoreData, StoreOrCaller, StoreOrCallerResource},
};
use rustler::{
    env::SavedTerm,
    types::{tuple::make_tuple, ListIterator, LocalPid},
    Encoder, Env, Error, MapIterator, NifMap, NifResult, OwnedEnv, ResourceArc, Term, TermType,
};
use std::ops::Deref;
use std::sync::Mutex;
use wasmtime::{Instance, Linker, Module, Trap, Val, ValType};

#[derive(NifMap)]
pub struct LinkedModule {
    pub name: String,
    pub module_resource: ResourceArc<ModuleResource>,
}

pub struct InstanceResource {
    pub inner: Mutex<Instance>,
}

#[rustler::resource_impl()]
impl rustler::Resource for InstanceResource {}

// creates a new instance from the given Wasm bytes
// expects the following elixir params
//
// * store (StoreResource): the store the module was compiled with
// * module (ModuleResource): the compiled Wasm module
// * imports (map): a map defining eventual instance imports, may be empty if there are none.
//   structure: %{namespace_name: %{import_name: {:fn, param_types, result_types, captured_function}}}
#[rustler::nif(name = "instance_new")]
pub fn new(
    store_or_caller_resource: ResourceArc<StoreOrCallerResource>,
    module_resource: ResourceArc<ModuleResource>,
    imports: MapIterator,
    linked_modules: Vec<LinkedModule>,
) -> Result<ResourceArc<InstanceResource>, rustler::Error> {
    let module = module_resource.inner.lock().map_err(|e| {
        rustler::Error::Term(Box::new(format!(
            "Could not unlock module resource as the mutex was poisoned: {e}"
        )))
    })?;
    let store_or_caller: &mut StoreOrCaller =
        &mut *(store_or_caller_resource.inner.lock().map_err(|e| {
            rustler::Error::Term(Box::new(format!(
                "Could not unlock store_or_caller resource as the mutex was poisoned: {e}"
            )))
        })?);

    let instance = link_and_create_instance(store_or_caller, &module, imports, linked_modules)?;
    let resource = ResourceArc::new(InstanceResource {
        inner: Mutex::new(instance),
    });
    Ok(resource)
}

fn link_and_create_instance(
    store_or_caller: &mut StoreOrCaller,
    module: &Module,
    imports: MapIterator,
    linked_modules: Vec<LinkedModule>,
) -> Result<Instance, Error> {
    let mut linker = Linker::new(store_or_caller.engine());
    if let Some(_wasi_ctx) = &store_or_caller.data().wasi {
        linker.allow_shadowing(true);
        wasi_common::sync::add_to_linker(&mut linker, |s: &mut StoreData| s.wasi.as_mut().unwrap())
            .map_err(|err| Error::Term(Box::new(err.to_string())))?;
    }

    link_imports(store_or_caller.engine(), &mut linker, imports)?;
    link_modules(&mut linker, store_or_caller, linked_modules)?;

    linker
        .instantiate(store_or_caller, module)
        .map_err(|err| Error::Term(Box::new(err.to_string())))
}

#[rustler::nif(name = "instance_get_global_value")]
pub fn get_global_value(
    env: rustler::Env,
    store_or_caller_resource: ResourceArc<StoreOrCallerResource>,
    instance_resource: ResourceArc<InstanceResource>,
    global_name: String,
) -> NifResult<Term> {
    let instance: Instance = *(instance_resource.inner.lock().map_err(|e| {
        rustler::Error::Term(Box::new(format!(
            "Could not unlock instance resource as the mutex was poisoned: {e}"
        )))
    })?);
    let mut store_or_caller: &mut StoreOrCaller =
        &mut *(store_or_caller_resource.inner.lock().map_err(|e| {
            rustler::Error::Term(Box::new(format!(
                "Could not unlock instance/store resource as the mutex was poisoned: {e}"
            )))
        })?);

    let global = instance
        .get_global(&mut store_or_caller, &global_name)
        .ok_or_else(|| {
            rustler::Error::Term(Box::new(format!(
                "exported global `{global_name}` not found"
            )))
        })?;

    let value = global.get(store_or_caller);

    match value {
        Val::I32(i) => Ok(i.encode(env)),
        Val::I64(i) => Ok(i.encode(env)),
        Val::F32(i) => Ok(f32::from_bits(i).encode(env)),
        Val::F64(i) => Ok(f64::from_bits(i).encode(env)),
        Val::V128(i) => Ok(rustler::BigInt::from(i.as_u128()).encode(env)),
        Val::FuncRef(_) => Err(rustler::Error::Term(Box::new(
            "unable_to_return_func_ref_type",
        ))),
        Val::ExternRef(_) => Err(rustler::Error::Term(Box::new(
            "unable_to_return_extern_ref_type",
        ))),
        Val::AnyRef(_) => Err(rustler::Error::Term(Box::new(
            "unable_to_return_any_ref_type",
        ))),
    }
}

#[rustler::nif(name = "instance_set_global_value")]
pub fn set_global_value(
    store_or_caller_resource: ResourceArc<StoreOrCallerResource>,
    instance_resource: ResourceArc<InstanceResource>,
    global_name: String,
    new_value: Term,
) -> NifResult<()> {
    let instance: Instance = *(instance_resource.inner.lock().map_err(|e| {
        rustler::Error::Term(Box::new(format!(
            "Could not unlock instance resource as the mutex was poisoned: {e}"
        )))
    })?);
    let mut store_or_caller: &mut StoreOrCaller =
        &mut *(store_or_caller_resource.inner.lock().map_err(|e| {
            rustler::Error::Term(Box::new(format!(
                "Could not unlock instance/store resource as the mutex was poisoned: {e}"
            )))
        })?);

    let global = instance
        .get_global(&mut store_or_caller, &global_name)
        .ok_or_else(|| {
            rustler::Error::Term(Box::new(format!(
                "exported global `{global_name}` not found"
            )))
        })?;

    let global_type = global.ty(&store_or_caller).content().clone();

    let new_value = decode_term_as_wasm_value(global_type.clone(), new_value).ok_or_else(|| {
        rustler::Error::Term(Box::new(format!(
            "Cannot convert to a WebAssembly {:?} value. Given `{:?}`.",
            global_type,
            PrintableTermType::PrintTerm(new_value.get_type())
        )))
    })?;

    let val: Val = match new_value {
        WasmValue::I32(value) => value.into(),
        WasmValue::I64(value) => value.into(),
        WasmValue::F32(value) => value.into(),
        WasmValue::F64(value) => value.into(),
        WasmValue::V128(value) => value.into(),
    };

    global
        .set(store_or_caller, val)
        .map_err(|e| rustler::Error::Term(Box::new(format!("Could not set global: {e}"))))
}

#[rustler::nif(name = "instance_function_export_exists")]
pub fn function_export_exists(
    store_or_caller_resource: ResourceArc<StoreOrCallerResource>,
    instance_resource: ResourceArc<InstanceResource>,
    function_name: String,
) -> NifResult<bool> {
    let instance: Instance = *(instance_resource.inner.lock().map_err(|e| {
        rustler::Error::Term(Box::new(format!(
            "Could not unlock instance resource as the mutex was poisoned: {e}"
        )))
    })?);
    let store_or_caller: &mut StoreOrCaller =
        &mut *(store_or_caller_resource.inner.lock().map_err(|e| {
            rustler::Error::Term(Box::new(format!(
                "Could not unlock instance/store resource as the mutex was poisoned: {e}"
            )))
        })?);

    let result = functions::exists(&instance, store_or_caller, &function_name);
    Ok(result)
}

#[rustler::nif(name = "instance_call_exported_function")]
pub fn call_exported_function(
    env: rustler::Env,
    store_or_caller_resource: ResourceArc<StoreOrCallerResource>,
    instance_resource: ResourceArc<InstanceResource>,
    function_name: String,
    params: Term,
    from: Term,
) -> rustler::Atom {
    let _ = env; // Required by rustler macro, but we use OwnedEnv instead
                 // create erlang environment for the thread
    let mut thread_env = OwnedEnv::new();
    // copy over params into the thread environment
    let function_params = thread_env.save(params);
    let from = thread_env.save(from);

    TOKIO_RUNTIME.spawn(async move {
        // Execute function and get the result
        let result = execute_function(
            &mut thread_env,
            store_or_caller_resource,
            instance_resource,
            function_name,
            function_params,
        );

        // Send GenServer reply directly to the caller
        thread_env.run(|env| {
            let from_tuple = from.load(env).decode::<Term>().unwrap();
            let result_term = result
                .load(env)
                .decode::<Term>()
                .unwrap_or(atoms::error().encode(env));

            // GenServer.call from tuple is {pid, ref}
            let (caller_pid, ref_term) = from_tuple
                .decode::<(LocalPid, Term)>()
                .expect("from must be a GenServer {pid, ref} tuple");

            // Send GenServer reply format directly to caller: {ref, result}
            let _ = env.send(&caller_pid, make_tuple(env, &[ref_term, result_term]));
        });
    });

    atoms::ok()
}

fn execute_function(
    thread_env: &mut OwnedEnv,
    store_or_caller_resource: ResourceArc<StoreOrCallerResource>,
    instance_resource: ResourceArc<InstanceResource>,
    function_name: String,
    function_params: SavedTerm,
) -> SavedTerm {
    let result = thread_env.run(|env: Env| {
        let given_params = match function_params.load(env).decode::<Vec<Term>>() {
            Ok(vec) => vec,
            Err(_) => {
                return env
                    .error_tuple("could not load 'function params'")
                    .encode(env)
            }
        };
        let instance: Instance = *(instance_resource.deref().inner.lock().unwrap());
        let mut store_or_caller = store_or_caller_resource.deref().inner.lock().unwrap();
        let function_result = functions::find(&instance, &mut store_or_caller, &function_name);
        let function = match function_result {
            Some(func) => func,
            None => {
                return env
                    .error_tuple(&format!("exported function `{function_name}` not found"))
                    .encode(env)
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
            Err(reason) => return env.error_tuple(&reason).encode(env),
        };
        let results_count = function.ty(&*store_or_caller).results().len();
        let mut results = vec![Val::null_extern_ref(); results_count];
        let call_result = function.call(
            &mut *store_or_caller,
            function_params.as_slice(),
            &mut results,
        );
        match call_result {
            Ok(_) => (),
            Err(err) => {
                let reason = format!("{err}");
                if let Ok(trap) = err.downcast::<Trap>() {
                    return env
                        .error_tuple(format!(
                            "Error during function excecution ({trap}): {reason}"
                        ))
                        .encode(env);
                } else {
                    return env
                        .error_tuple(format!("Error during function excecution: {reason}"))
                        .encode(env);
                }
            }
        };
        let mut return_values: Vec<Term> = Vec::with_capacity(results_count);
        for value in results.iter().cloned() {
            return_values.push(match value {
                Val::I32(i) => i.encode(env),
                Val::I64(i) => i.encode(env),
                Val::F32(i) => f32::from_bits(i).encode(env),
                Val::F64(i) => f64::from_bits(i).encode(env),
                Val::V128(i) => rustler::BigInt::from(i.as_u128()).encode(env),
                Val::FuncRef(_) => {
                    return env
                        .error_tuple("unable_to_return_func_ref_type")
                        .encode(env)
                }
                Val::ExternRef(_) => {
                    return env
                        .error_tuple("unable_to_return_extern_ref_type")
                        .encode(env)
                }
                Val::AnyRef(_) => {
                    return env.error_tuple("unable_to_return_any_ref_type").encode(env)
                }
            })
        }

        // Return nil for void functions (no return values), otherwise return the list
        let result_term = if return_values.is_empty() {
            atoms::__nil__().encode(env)
        } else {
            return_values.encode(env)
        };

        // Return success tuple
        make_tuple(env, &[atoms::ok().encode(env), result_term]).encode(env)
    });
    thread_env.save(result)
}

#[derive(Debug, Copy, Clone)]
pub enum WasmValue {
    I32(i32),
    I64(i64),
    F32(f32),
    F64(f64),
    V128(u128),
}

fn decode_term_as_wasm_value(expected_type: ValType, term: Term) -> Option<WasmValue> {
    let value = match (expected_type, term.get_type()) {
        (ValType::I32, TermType::Integer | TermType::Float) => match term.decode::<i32>() {
            Ok(value) => WasmValue::I32(value),
            Err(_) => return None,
        },
        (ValType::I64, TermType::Integer | TermType::Float) => match term.decode::<i64>() {
            Ok(value) => WasmValue::I64(value),
            Err(_) => return None,
        },
        (ValType::F32, TermType::Integer | TermType::Float) => match term.decode::<f32>() {
            Ok(value) => {
                if value.is_finite() {
                    WasmValue::F32(value)
                } else {
                    return None;
                }
            }
            Err(_) => return None,
        },
        (ValType::F64, TermType::Integer | TermType::Float) => match term.decode::<f64>() {
            Ok(value) => WasmValue::F64(value),
            Err(_) => return None,
        },
        (ValType::V128, TermType::Integer | TermType::Float) => {
            match term.decode::<rustler::BigInt>() {
                Ok(value) => {
                    let (_sign, mut bytes_vec) = value.to_bytes_be();
                    if value < rustler::BigInt::ZERO {
                        return None;
                    }

                    // prepend 0 bytes to make it 16 bytes long. `to_bytes_be()` only returns leading non-zero bytes
                    while bytes_vec.len() < 16 {
                        bytes_vec.insert(0, 0);
                    }
                    let bytes: [u8; 16] = match bytes_vec.len() {
                        16 => {
                            let mut bytes = [0; 16];
                            bytes.copy_from_slice(&bytes_vec);
                            bytes
                        }
                        _ => return None,
                    };
                    WasmValue::V128(u128::from_be_bytes(bytes))
                }
                Err(_) => return None,
            }
        }
        (_val_type, _term_type) => return None,
    };

    Some(value)
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
        let value = match (
            decode_term_as_wasm_value(param.clone(), given_param),
            given_param.get_type(),
        ) {
            (Some(value), _) => value,
            (_, TermType::Integer | TermType::Float) => {
                return Err(format!(
                    "Cannot convert argument #{} to a WebAssembly {} value.",
                    nth + 1,
                    format!("{param:?}").to_lowercase()
                ))
            }
            (_, term_type) => {
                return Err(format!(
                    "Cannot convert argument #{} to a WebAssembly {:?} value. Given `{:?}`.",
                    nth + 1,
                    param,
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
            WasmValue::V128(value) => (*value).into(),
        })
        .collect()
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
                    "could not convert callback result param to expected return signature: {reason}"
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
