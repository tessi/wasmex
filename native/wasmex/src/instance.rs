use rustler::{
    dynamic::TermType,
    env::{OwnedEnv, SavedTerm},
    resource::ResourceArc,
    types::binary::Binary,
    types::tuple::make_tuple,
    {Encoder, Env as RustlerEnv, Error, MapIterator, Term},
};
use std::sync::Mutex;
use std::thread;

use wasmer::{Instance, Module, Store, Type, Val};

use crate::{
    atoms, environment::Environment, functions, memory::memory_from_instance,
    printable_term_type::PrintableTermType,
};

pub struct InstanceResource {
    pub instance: Mutex<Instance>,
}

// creates a new instance from the given WASM bytes
// expects the following elixir params
//
// * bytes (binary): the bytes of the WASM module
// * imports (map): a map defining eventual instance imports, may be empty if there are none.
//   structure: %{namespace_name: %{import_name: {TODO: signature}}}
pub fn new_from_bytes<'a>(env: RustlerEnv<'a>, args: &[Term<'a>]) -> Result<Term<'a>, Error> {
    let binary: Binary = args[0].decode()?;
    let imports: MapIterator = args[1].decode()?;
    let bytes = binary.as_slice();

    let mut environment = Environment::new();
    let import_object = environment.import_object(imports)?;
    let store = Store::default();
    let module = match Module::new(&store, &bytes) {
        Ok(module) => module,
        Err(e) => {
            return Ok((atoms::error(), format!("Could not compule module: {:?}", e)).encode(env))
        }
    };
    let instance = match Instance::new(&module, &import_object) {
        Ok(instance) => instance,
        Err(e) => return Ok((atoms::error(), format!("Cannot Instantiate: {:?}", e)).encode(env)),
    };
    let memory = memory_from_instance(&instance)?.clone();
    environment.memory.initialize(memory);

    let resource = ResourceArc::new(InstanceResource {
        instance: Mutex::new(instance),
    });
    Ok((atoms::ok(), resource).encode(env))
}

pub fn function_export_exists<'a>(
    env: RustlerEnv<'a>,
    args: &[Term<'a>],
) -> Result<Term<'a>, Error> {
    let resource: ResourceArc<InstanceResource> = args[0].decode()?;
    let function_name: String = args[1].decode()?;
    let instance = resource.instance.lock().unwrap();

    Ok(functions::exists(&instance, &function_name).encode(env))
}

pub fn call_exported_function<'a>(
    env: RustlerEnv<'a>,
    args: &[Term<'a>],
) -> Result<Term<'a>, Error> {
    let pid = env.pid();
    // create erlang environment for the thread
    let mut thread_env = OwnedEnv::new();
    // copy over params into the thread environment
    let resource: ResourceArc<InstanceResource> = args[0].decode()?;
    let function_name: String = args[1].decode()?;
    let function_params = thread_env.save(args[2]);
    let from = thread_env.save(args[3]);
    args[3].decode::<Term>()?; // make sure the `from` param exists, as we cannot safely return errors without it in execute_function
    thread::spawn(move || {
        thread_env.send_and_clear(&pid, |thread_env| {
            execute_function(thread_env, resource, function_name, function_params, from)
        })
    });

    Ok(atoms::ok().encode(env))
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
        Ok(vec) => map_to_wasmer_values(vec),
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

#[derive(Clone, Copy)]
union RustValueStore {
    i32: i32,
    i64: i64,
    f32: f32,
    f64: f64,
}

#[derive(Clone)]
enum RustValueTag {
    I32,
    I64,
    F32,
    F64,
}

#[derive(Clone)]
pub struct RustValue {
    tag: RustValueTag,
    store: RustValueStore,
}

pub fn decode_function_param_terms(
    params: &[Type],
    function_param_terms: Vec<Term>,
) -> Result<Vec<RustValue>, String> {
    if 0 != params.len() as isize - function_param_terms.len() as isize {
        return Err(format!(
            "number of params does not match. expected {}, got {}",
            params.len(),
            function_param_terms.len()
        ));
    }

    let mut function_params = Vec::<RustValue>::with_capacity(params.len() as usize);
    for (nth, (param, given_param)) in params
        .iter()
        .zip(function_param_terms.into_iter())
        .enumerate()
    {
        let value = match (param, given_param.get_type()) {
            (Type::I32, TermType::Number) => RustValue {
                tag: RustValueTag::I32,
                store: RustValueStore {
                    i32: (match given_param.decode() {
                        Ok(value) => value,
                        Err(_) => {
                            return Err(format!(
                                "Cannot convert argument #{} to a WebAssembly i32 value.",
                                nth + 1
                            ));
                        }
                    }),
                },
            },
            (Type::I64, TermType::Number) => RustValue {
                tag: RustValueTag::I64,
                store: RustValueStore {
                    i64: (match given_param.decode() {
                        Ok(value) => value,
                        Err(_) => {
                            return Err(format!(
                                "Cannot convert argument #{} to a WebAssembly i64 value.",
                                nth + 1
                            ));
                        }
                    }),
                },
            },
            (Type::F32, TermType::Number) => RustValue {
                tag: RustValueTag::F32,
                store: RustValueStore {
                    f32: (match given_param.decode::<f32>() {
                        Ok(value) => {
                            if value.is_finite() {
                                value
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
                    }),
                },
            },
            (Type::F64, TermType::Number) => RustValue {
                tag: RustValueTag::F64,
                store: RustValueStore {
                    f64: (match given_param.decode() {
                        Ok(value) => value,
                        Err(_) => {
                            return Err(format!(
                                "Cannot convert argument #{} to a WebAssembly f64 value.",
                                nth + 1
                            ));
                        }
                    }),
                },
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

pub fn map_to_wasmer_values(values: Vec<RustValue>) -> Vec<Val> {
    // safety: We access union type fields which may be unsafe if the value is not initialized.
    //         However, we only ever create tagges RustValues with a matching value - they are always initialized.
    values
        .into_iter()
        .map(|value| match value {
            RustValue {
                tag: RustValueTag::I32,
                store: s,
            } => Val::I32(unsafe { s.i32 }),
            RustValue {
                tag: RustValueTag::I64,
                store: s,
            } => Val::I64(unsafe { s.i64 }),
            RustValue {
                tag: RustValueTag::F32,
                store: s,
            } => Val::F32(unsafe { s.f32 }),
            RustValue {
                tag: RustValueTag::F64,
                store: s,
            } => Val::F64(unsafe { s.f64 }),
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
