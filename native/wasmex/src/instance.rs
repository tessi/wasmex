use rustler::{
    dynamic::TermType,
    env::{OwnedEnv, SavedTerm},
    resource::ResourceArc,
    types::binary::Binary,
    types::tuple::make_tuple,
    NifResult, {Encoder, Env as RustlerEnv, MapIterator, Term},
};
use std::sync::Mutex;
use std::thread;

use wasmer::{Instance, Module, Store, Type, Val, Value};

use crate::{
    atoms, environment::Environment, functions, memory::memory_from_instance,
    printable_term_type::PrintableTermType,
};

pub struct InstanceResource {
    pub instance: Mutex<Instance>,
}

#[derive(NifTuple)]
pub struct InstanceResourceResponse {
    ok: rustler::Atom,
    resource: ResourceArc<InstanceResource>,
}

// creates a new instance from the given WASM bytes
// expects the following elixir params
//
// * bytes (binary): the bytes of the WASM module
// * imports (map): a map defining eventual instance imports, may be empty if there are none.
//   structure: %{namespace_name: %{import_name: {TODO: signature}}}
#[rustler::nif(name = "instance_new_from_bytes")]
pub fn new_from_bytes(binary: Binary, imports: MapIterator) -> NifResult<InstanceResourceResponse> {
    let bytes = binary.as_slice();

    let mut environment = Environment::new();
    let import_object = environment.import_object(imports)?; // TODO: maybe we can improve this with a map type!
    let store = Store::default();
    let module = match Module::new(&store, &bytes) {
        Ok(module) => module,
        Err(e) => {
            return Err(rustler::Error::Term(Box::new(format!(
                "Could not compule module: {:?}",
                e
            ))))
        }
    };
    let instance = match Instance::new(&module, &import_object) {
        Ok(instance) => instance,
        Err(e) => {
            return Err(rustler::Error::Term(Box::new(format!(
                "Cannot Instantiate: {:?}",
                e
            ))))
        }
    };
    let memory = memory_from_instance(&instance)?.clone();
    environment.memory.initialize(memory);

    let resource = ResourceArc::new(InstanceResource {
        instance: Mutex::new(instance),
    });
    Ok(InstanceResourceResponse {
        ok: atoms::ok(),
        resource,
    })
}

#[rustler::nif(name = "instance_function_export_exists")]
pub fn function_export_exists(
    resource: ResourceArc<InstanceResource>,
    function_name: String,
) -> bool {
    let instance = resource.instance.lock().unwrap();

    functions::exists(&instance, &function_name)
}

#[rustler::nif(name = "instance_call_exported_function", schedule = "DirtyCpu")]
pub fn call_exported_function<'a>(
    env: rustler::Env<'a>,
    resource: ResourceArc<InstanceResource>,
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
            execute_function(thread_env, resource, function_name, function_params, from)
        })
    });

    atoms::ok()
}

fn execute_function(
    thread_env: RustlerEnv,
    resource: ResourceArc<InstanceResource>,
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
    let instance = resource.instance.lock().unwrap();
    let function = match functions::find(&instance, &function_name) {
        Ok(f) => f,
        Err(_) => {
            return make_error_tuple(
                &thread_env,
                &format!("exported function `{}` not found", function_name),
                from,
            )
        }
    };
    let function_params = match decode_function_param_terms(&function.ty().params(), given_params) {
        Ok(vec) => map_to_wasmer_values(&vec),
        Err(reason) => return make_error_tuple(&thread_env, &reason, from),
    };

    let results = match function.call(function_params.as_slice()) {
        Ok(results) => results,
        Err(e) => {
            return make_error_tuple(
                &thread_env,
                &format!("Error during function excecution: `{}`.", e),
                from,
            )
        }
    };
    let mut return_values: Vec<Term> = Vec::with_capacity(results.len());
    for value in results.to_vec() {
        return_values.push(match value {
            Val::I32(i) => i.encode(thread_env),
            Val::I64(i) => i.encode(thread_env),
            Val::F32(i) => i.encode(thread_env),
            Val::F64(i) => i.encode(thread_env),
            // encoding V128 is not yet supported by rustler
            Val::V128(_) => {
                return make_error_tuple(&thread_env, &"unable_to_return_v128_type", from)
            }
            Val::FuncRef(_) => {
                return make_error_tuple(&thread_env, &"unable_to_return_func_ref_type", from)
            }
            Val::ExternRef(_) => {
                return make_error_tuple(&thread_env, &"unable_to_return_extern_ref_type", from)
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
    params: &[Type],
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
            (Type::I32, TermType::Number) => match given_param.decode::<i32>() {
                Ok(value) => WasmValue::I32(value),
                Err(_) => {
                    return Err(format!(
                        "Cannot convert argument #{} to a WebAssembly i32 value.",
                        nth + 1
                    ));
                }
            },
            (Type::I64, TermType::Number) => match given_param.decode::<i64>() {
                Ok(value) => WasmValue::I64(value),
                Err(_) => {
                    return Err(format!(
                        "Cannot convert argument #{} to a WebAssembly i64 value.",
                        nth + 1
                    ));
                }
            },
            (Type::F32, TermType::Number) => match given_param.decode::<f32>() {
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
            (Type::F64, TermType::Number) => match given_param.decode::<f64>() {
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

pub fn map_to_wasmer_values(values: &[WasmValue]) -> Vec<Val> {
    values
        .iter()
        .map(|value| match value {
            WasmValue::I32(value) => Value::I32(*value),
            WasmValue::I64(value) => Value::I64(*value),
            WasmValue::F32(value) => Value::F32(*value),
            WasmValue::F64(value) => Value::F64(*value),
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
