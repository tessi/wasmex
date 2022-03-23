use rustler::{
    dynamic::TermType,
    env::{OwnedEnv, SavedTerm},
    resource::ResourceArc,
    types::tuple::make_tuple,
    types::ListIterator,
    Encoder, Env as RustlerEnv, MapIterator, NifResult, Term,
};
use std::sync::Mutex;
use std::thread;

use wasmer::{ChainableNamedResolver, Instance, Type, Val, Value};
use wasmer_wasi::WasiState;

use crate::{
    atoms, environment::Environment, functions, memory::memory_from_instance,
    module::ModuleResource, pipe::PipeResource, printable_term_type::PrintableTermType,
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
// * module (ModuleResource): the compiled WASM module
// * imports (map): a map defining eventual instance imports, may be empty if there are none.
//   structure: %{namespace_name: %{import_name: {:fn, param_types, result_types, captured_function}}}
#[rustler::nif(name = "instance_new")]
pub fn new(
    module_resource: ResourceArc<ModuleResource>,
    imports: MapIterator,
) -> NifResult<InstanceResourceResponse> {
    let mut environment = Environment::new();
    let import_object = environment.import_object(imports)?;
    let module = module_resource.module.lock().unwrap();
    let instance = match Instance::new(&module, &import_object) {
        Ok(instance) => instance,
        Err(e) => {
            return Err(rustler::Error::Term(Box::new(format!(
                "Cannot Instantiate: {:?}",
                e
            ))))
        }
    };

    if let Ok(memory) = memory_from_instance(&instance) {
        environment.memory.initialize(memory.clone());
    }

    let resource = ResourceArc::new(InstanceResource {
        instance: Mutex::new(instance),
    });
    Ok(InstanceResourceResponse {
        ok: atoms::ok(),
        resource,
    })
}

// Creates a new instance from the given WASM bytes.
// Expects the following elixir params:
//
// * module (ModuleResource): the compiled WASM module
// * imports (map): a map defining eventual instance imports, may be empty if there are none.
//   structure: %{namespace_name: %{import_name: {:fn, param_types, result_types, captured_function}}}
// * wasi_args (list of Strings): a list of argument strings
// * wasi_env: (map String->String): a map containing environment variable definitions, each of the type `"NAME" => "value"`
// * options: A map allowing the following keys
//   * stdin (optional): A pipe that will be passed as stdin to the WASM module
//   * stdout (optional): A pipe that will be passed as stdout to the WASM module
//   * stderr (optional): A pipe that will be passed as stderr to the WASM module
#[rustler::nif(name = "instance_new_wasi")]
pub fn new_wasi<'a>(
    env: rustler::Env<'a>,
    module_resource: ResourceArc<ModuleResource>,
    imports: MapIterator,
    wasi_args: ListIterator,
    wasi_env: MapIterator,
    options: Term<'a>,
) -> NifResult<InstanceResourceResponse> {
    let wasi_args = wasi_args
        .map(|term: Term| term.decode::<String>().map(|s| s.into_bytes()))
        .collect::<Result<Vec<Vec<u8>>, _>>()?;
    let wasi_env = wasi_env
        .map(|(key, val)| {
            key.decode::<String>()
                .and_then(|key| val.decode::<String>().map(|val| (key, val)))
        })
        .collect::<Result<Vec<(String, String)>, _>>()?;

    let mut environment = Environment::new();
    let mut wasi_wasmer_env = create_wasi_env(wasi_args, wasi_env, options, env)?;
    let module = module_resource.module.lock().unwrap();

    // creates as WASI import object and merges imports from elixir into them
    // this allows overwriting certain WASI functions from elixir
    let import_object = wasi_wasmer_env.import_object(&module).map_err(|e| {
        rustler::Error::Term(Box::new(format!("Could not create import object: {:?}", e)))
    })?;

    let import_object_overwrites = environment.import_object(imports)?;
    let resolver = import_object.chain_front(import_object_overwrites);

    let instance = match Instance::new(&module, &resolver) {
        Ok(instance) => instance,
        Err(e) => {
            return Err(rustler::Error::Term(Box::new(format!(
                "Cannot instantiate: {:?}",
                e
            ))))
        }
    };

    if let Ok(memory) = memory_from_instance(&instance) {
        environment.memory.initialize(memory.clone());
    }

    let resource = ResourceArc::new(InstanceResource {
        instance: Mutex::new(instance),
    });
    Ok(InstanceResourceResponse {
        ok: atoms::ok(),
        resource,
    })
}

fn create_wasi_env<'a>(
    wasi_args: Vec<Vec<u8>>,
    wasi_env: Vec<(String, String)>,
    options: Term<'a>,
    env: RustlerEnv<'a>,
) -> Result<wasmer_wasi::WasiEnv, rustler::Error> {
    let mut state_builder = WasiState::new("wasmex");
    state_builder.args(wasi_args);
    for (key, value) in wasi_env {
        state_builder.env(key, value);
    }
    wasi_stdin(options, env, &mut state_builder)?;
    wasi_stdout(options, env, &mut state_builder)?;
    wasi_stderr(options, env, &mut state_builder)?;
    wasi_preopen_directories(options, env, &mut state_builder)?;
    state_builder.finalize().map_err(|e| {
        rustler::Error::Term(Box::new(format!("Could not create WASI state: {:?}", e)))
    })
}

fn wasi_preopen_directories<'a>(
    options: Term<'a>,
    env: RustlerEnv<'a>,
    state_builder: &mut wasmer_wasi::WasiStateBuilder,
) -> Result<(), rustler::Error> {
    if let Some(preopen) = options
        .map_get("preopen".encode(env))
        .ok()
        .and_then(MapIterator::new)
    {
        for (key, opts) in preopen {
            let directory: &str = key.decode()?;
            state_builder
                .preopen(|builder| {
                    let builder = builder.directory(directory);
                    if let Ok(alias) = opts
                        .map_get("alias".encode(env))
                        .and_then(|term| term.decode())
                    {
                        builder.alias(alias);
                    }

                    if let Ok(flags) = opts
                        .map_get("flags".encode(env))
                        .and_then(|term| term.decode::<ListIterator>())
                    {
                        for flag in flags {
                            if flag.eq(&atoms::read().to_term(env)) {
                                builder.read(true);
                            }
                            if flag.eq(&atoms::write().to_term(env)) {
                                builder.write(true);
                            }
                            if flag.eq(&atoms::create().to_term(env)) {
                                builder.create(true);
                            }
                        }
                    }
                    builder
                })
                .map_err(|e| {
                    rustler::Error::Term(Box::new(format!("Could not create WASI state: {:?}", e)))
                })?;
        }
    }
    Ok(())
}

fn wasi_stderr(
    options: Term,
    env: RustlerEnv,
    state_builder: &mut wasmer_wasi::WasiStateBuilder,
) -> Result<(), rustler::Error> {
    if let Ok(resource) = pipe_from_wasi_options(options, "stderr", &env) {
        let pipe = resource.pipe.lock().map_err(|_e| {
            rustler::Error::Term(Box::new(
                "Could not unlock resource as the mutex was poisoned.",
            ))
        })?;
        state_builder.stderr(Box::new(pipe.clone()));
    }
    Ok(())
}

fn wasi_stdout(
    options: Term,
    env: RustlerEnv,
    state_builder: &mut wasmer_wasi::WasiStateBuilder,
) -> Result<(), rustler::Error> {
    if let Ok(resource) = pipe_from_wasi_options(options, "stdout", &env) {
        let pipe = resource.pipe.lock().map_err(|_e| {
            rustler::Error::Term(Box::new(
                "Could not unlock resource as the mutex was poisoned.",
            ))
        })?;
        state_builder.stdout(Box::new(pipe.clone()));
    }
    Ok(())
}

fn wasi_stdin(
    options: Term,
    env: RustlerEnv,
    state_builder: &mut wasmer_wasi::WasiStateBuilder,
) -> Result<(), rustler::Error> {
    if let Ok(resource) = pipe_from_wasi_options(options, "stdin", &env) {
        let pipe = resource.pipe.lock().map_err(|_e| {
            rustler::Error::Term(Box::new(
                "Could not unlock resource as the mutex was poisoned.",
            ))
        })?;
        state_builder.stdin(Box::new(pipe.clone()));
    }
    Ok(())
}

fn pipe_from_wasi_options(
    options: Term,
    key: &str,
    env: &rustler::Env,
) -> Result<ResourceArc<PipeResource>, rustler::Error> {
    options
        .map_get(key.encode(*env))
        .and_then(|pipe_term| pipe_term.map_get(atoms::resource().encode(*env)))
        .and_then(|term| term.decode::<ResourceArc<PipeResource>>())
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
    let function_params = match decode_function_param_terms(function.ty().params(), given_params) {
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
    for value in results.iter().cloned() {
        return_values.push(match value {
            Val::I32(i) => i.encode(thread_env),
            Val::I64(i) => i.encode(thread_env),
            Val::F32(i) => i.encode(thread_env),
            Val::F64(i) => i.encode(thread_env),
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
