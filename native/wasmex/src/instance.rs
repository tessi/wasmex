use rustler::dynamic::TermType;
use rustler::env::{OwnedEnv, SavedTerm};
use rustler::resource::ResourceArc;
use rustler::types::binary::Binary;
use rustler::types::tuple::make_tuple;
use rustler::{Encoder, Env, Error, Term};
use std::sync::Mutex;
use std::thread;
use wasmer_runtime::{self as runtime, imports};
use wasmer_runtime_core::instance::DynFunc;
use wasmer_runtime_core::types::Type;

use crate::printable_term_type::PrintableTermType;
use crate::{atoms, functions};

pub struct InstanceResource {
    pub instance: Mutex<runtime::Instance>,
}

pub fn new_from_bytes<'a>(env: Env<'a>, args: &[Term<'a>]) -> Result<Term<'a>, Error> {
    let binary: Binary = args[0].decode()?;
    let bytes = binary.as_slice();

    let import_object = imports! {};
    let instance = match runtime::instantiate(bytes, &import_object) {
        Ok(instance) => instance,
        Err(e) => return Ok((atoms::error(), format!("Cannot Instantiate: {:?}", e)).encode(env)),
    };

    let resource = ResourceArc::new(InstanceResource {
        instance: Mutex::new(instance),
    });
    Ok((atoms::ok(), resource).encode(env))
}

pub fn function_export_exists<'a>(env: Env<'a>, args: &[Term<'a>]) -> Result<Term<'a>, Error> {
    let resource: ResourceArc<InstanceResource> = args[0].decode()?;
    let function_name: String = args[1].decode()?;
    let instance = resource.instance.lock().unwrap();

    Ok(functions::exists(&instance, &function_name).encode(env))
}

pub fn call_exported_function<'a>(env: Env<'a>, args: &[Term<'a>]) -> Result<Term<'a>, Error> {
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

fn execute_function<'a>(
    thread_env: Env<'a>,
    resource: ResourceArc<InstanceResource>,
    function_name: String,
    function_params: SavedTerm,
    from: SavedTerm,
) -> Term<'a> {
    let from = from
        .load(thread_env)
        .decode::<Term>()
        .unwrap_or("could not load 'from' param".encode(thread_env));
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
    let function_params = match decode_function_param_terms(&function, given_params) {
        Ok(vec) => vec,
        Err(reason) => return make_error_tuple(&thread_env, &reason, from),
    };

    let results = match function.call(function_params.as_slice()) {
        Ok(results) => results,
        Err(e) => return make_error_tuple(&thread_env, &format!("Runtime Error `{}`.", e), from),
    };
    let mut return_values: Vec<Term> = Vec::with_capacity(results.len());
    for value in results {
        return_values.push(match value {
            runtime::Value::I32(i) => i.encode(thread_env),
            runtime::Value::I64(i) => i.encode(thread_env),
            runtime::Value::F32(i) => i.encode(thread_env),
            runtime::Value::F64(i) => i.encode(thread_env),
            // encoding V128 is not yet supported by rustler
            runtime::Value::V128(_) => {
                return make_error_tuple(&thread_env, &"unable_to_return_v128_type", from)
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

fn decode_function_param_terms(
    function: &DynFunc,
    function_param_terms: Vec<Term>,
) -> Result<Vec<runtime::Value>, String> {
    let signature = function.signature();
    let params = signature.params();
    if 0 != params.len() as isize - function_param_terms.len() as isize {
        return Err(format!(
            "number of params does not match. expected {}, got {}",
            params.len(),
            function_param_terms.len()
        ));
    }

    let mut function_params = Vec::<runtime::Value>::with_capacity(params.len() as usize);
    for (nth, (param, given_param)) in params
        .iter()
        .zip(function_param_terms.into_iter())
        .enumerate()
    {
        let value = match (param, given_param.get_type()) {
            (Type::I32, TermType::Number) => runtime::Value::I32(match given_param.decode() {
                Ok(value) => value,
                Err(_) => {
                    return Err(format!(
                        "Cannot convert argument #{} to a WebAssembly i32 value.",
                        nth + 1
                    ))
                }
            }),
            (Type::I64, TermType::Number) => runtime::Value::I64(match given_param.decode() {
                Ok(value) => value,
                Err(_) => {
                    return Err(format!(
                        "Cannot convert argument #{} to a WebAssembly i64 value.",
                        nth + 1
                    ))
                }
            }),
            (Type::F32, TermType::Number) => {
                runtime::Value::F32(match given_param.decode::<f32>() {
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
                        ))
                    }
                })
            }
            (Type::F64, TermType::Number) => runtime::Value::F64(match given_param.decode() {
                Ok(value) => value,
                Err(_) => {
                    return Err(format!(
                        "Cannot convert argument #{} to a WebAssembly f64 value.",
                        nth + 1
                    ))
                }
            }),
            (_, term_type) => {
                return Err(format!(
                    "Cannot convert argument #{} to a WebAssembly value. Given `{:?}`.",
                    nth + 1,
                    PrintableTermType::PrintTerm(term_type)
                ))
            }
        };
        function_params.push(value);
    }
    Ok(function_params)
}

fn make_error_tuple<'a>(env: &Env<'a>, reason: &str, from: Term<'a>) -> Term<'a> {
    make_tuple(
        *env,
        &[
            atoms::returned_function_call().encode(*env),
            env.error_tuple(reason),
            from,
        ],
    )
}
