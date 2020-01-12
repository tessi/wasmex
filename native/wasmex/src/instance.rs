use rustler::dynamic::TermType;
use rustler::resource::ResourceArc;
use rustler::types::binary::Binary;
use rustler::{Encoder, Env, Error, Term};
use std::sync::Mutex;
use wasmer_runtime::{self as runtime, imports};
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
    let instance = runtime::instantiate(bytes, &import_object)
        .map_err(|_| Error::Atom("could_not_instantiate"))?;

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
    let resource: ResourceArc<InstanceResource> = args[0].decode()?;
    let given_name: String = args[1].decode()?;
    let given_params: Vec<Term> = args[2].decode()?;
    let instance = resource.instance.lock().unwrap();

    let function = match functions::find(&instance, &given_name) {
        Ok(f) => f,
        Err(_) => {
            return Err(Error::RaiseTerm(Box::new(format!(
                "exported function `{}` not found",
                given_name
            ))))
        }
    };
    let signature = function.signature();
    let params = signature.params();
    if 0 != params.len() as isize - given_params.len() as isize {
        return Err(Error::RaiseTerm(Box::new(format!(
            "number of params does not match. expected {}, got {}",
            params.len(),
            given_params.len()
        ))));
    }

    let mut function_params = Vec::<runtime::Value>::with_capacity(params.len() as usize);
    for (nth, (param, given_param)) in params.iter().zip(given_params.into_iter()).enumerate() {
        let value = match (param, given_param.get_type()) {
            (Type::I32, TermType::Number) => runtime::Value::I32(match given_param.decode() {
                Ok(value) => value,
                Err(_) => {
                    return Err(Error::RaiseTerm(Box::new(format!(
                        "Cannot convert argument #{} to a WebAssembly i32 value.",
                        nth + 1
                    ))))
                }
            }),
            (Type::I64, TermType::Number) => runtime::Value::I64(match given_param.decode() {
                Ok(value) => value,
                Err(_) => {
                    return Err(Error::RaiseTerm(Box::new(format!(
                        "Cannot convert argument #{} to a WebAssembly i64 value.",
                        nth + 1
                    ))))
                }
            }),
            (Type::F32, TermType::Number) => runtime::Value::F32(match given_param.decode() {
                Ok(value) => value,
                Err(_) => {
                    return Err(Error::RaiseTerm(Box::new(format!(
                        "Cannot convert argument #{} to a WebAssembly f32 value.",
                        nth + 1
                    ))))
                }
            }),
            (Type::F64, TermType::Number) => runtime::Value::F64(match given_param.decode() {
                Ok(value) => value,
                Err(_) => {
                    return Err(Error::RaiseTerm(Box::new(format!(
                        "Cannot convert argument #{} to a WebAssembly f64 value.",
                        nth + 1
                    ))))
                }
            }),
            (_, term_type) => {
                return Err(Error::RaiseTerm(Box::new(format!(
                    "Cannot convert argument #{} to a WebAssembly value. Given `{:?}`.",
                    nth + 1,
                    PrintableTermType::PrintTerm(term_type)
                ))))
            }
        };
        function_params.push(value);
    }

    let results = match function.call(function_params.as_slice()) {
        Ok(results) => results,
        Err(e) => return Ok((atoms::error(), &format!("Runtime Error `{}`.", e)).encode(env)),
    };

    if results.is_empty() {
        Ok(atoms::__nil__().encode(env))
    } else {
        let return_value = match results[0] {
            runtime::Value::I32(result) => result.encode(env),
            runtime::Value::I64(result) => result.encode(env),
            runtime::Value::F32(result) => result.encode(env),
            runtime::Value::F64(result) => result.encode(env),
            // encoding V128 is not yet supported by rustler
            runtime::Value::V128(_result) => return Err(Error::Atom("unable_to_return_v128_type")),
        };
        Ok(return_value)
    }
}
