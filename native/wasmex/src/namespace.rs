//! Namespace API of an WebAssembly instance.

use rustler::{
    resource::ResourceArc, types::ListIterator, types::tuple, Atom, Encoder, Env, Error, MapIterator, OwnedEnv, Term,
};
use std::sync::{Arc, Condvar, Mutex};
use wasmer_runtime::{self as runtime};
use wasmer_runtime_core::{
    import::Namespace, typed_func::DynamicFunc, types::FuncSig, types::Type, types::Value, vm::Ctx,
};

use crate::{atoms, instance::decode_function_param_terms};

pub struct CallbackTokenResource {
    pub token: (
        Mutex<Option<(bool, Vec<runtime::Value>)>>,
        Condvar,
        Vec<Type>,
        Vec<Type>,
    ),
}

pub fn create_from_definition(
    namespace_name: &String,
    definition: Term,
) -> Result<Namespace, Error> {
    let mut namespace = Namespace::new();
    let definition: MapIterator = definition.decode()?;
    for (name, import) in definition {
        let name = name.decode::<String>()?;
        namespace.insert(
            name.clone(),
            create_imported_function(namespace_name.clone(), name, import)?,
        );
    }
    Ok(namespace)
}

fn term_to_arg_type(
    term: Term
) -> Result<Type, Error> {
    match Atom::from_term(term) {
        Ok(atom) => {
            if atoms::i32().eq(&atom) {
                Ok(Type::I32)
            } else if atoms::i64().eq(&atom) {
                Ok(Type::I64)
            } else if atoms::f32().eq(&atom) {
                Ok(Type::F32)
            } else if atoms::f64().eq(&atom) {
                Ok(Type::F64)
            } else if atoms::v128().eq(&atom) {
                Ok(Type::V128)
            } else {
                Err(Error::Atom("unknown"))
            }
        }
        Err(_) => {
            Err(Error::Atom("not_an_atom"))
        }
    }
}

fn create_imported_function(
    namespace_name: String,
    import_name: String,
    definition: Term,
) -> Result<DynamicFunc<'static>, Error> {
    let pid = definition.get_env().pid();

    let import_tuple = tuple::get_tuple(definition)?;

    let param_term = import_tuple.get(0).ok_or_else(|| Error::Atom("missing_params"))?;
    let results_term = import_tuple.get(1).ok_or_else(|| Error::Atom("missing_results"))?;

    let params_signature = param_term
        .decode::<ListIterator>()?
        .map(|term| term_to_arg_type(term))
        .collect::<Result<Vec<Type>, _>>()?;

    let results_signature = results_term
        .decode::<ListIterator>()?
        .map(|term| term_to_arg_type(term))
        .collect::<Result<Vec<Type>, _>>()?;

    let signature = Arc::new(FuncSig::new(params_signature.clone(), results_signature.clone()));

    Ok(DynamicFunc::new(
        signature,
        move |_ctx: &mut Ctx, params: &[Value]| -> Vec<runtime::Value> {
            let callback_token = ResourceArc::new(CallbackTokenResource {
                token: (
                           Mutex::new(None),
                           Condvar::new(),
                           params_signature.clone(),
                           results_signature.clone(),
                       ),
            });

            let mut msg_env = OwnedEnv::new();
            msg_env.send_and_clear(&pid.clone(), |env| {
                let mut callback_params: Vec<Term> = Vec::with_capacity(params.len());
                for value in params {
                    callback_params.push(match value {
                        runtime::Value::I32(i) => i.encode(env),
                        runtime::Value::I64(i) => i.encode(env),
                        runtime::Value::F32(i) => i.encode(env),
                        runtime::Value::F64(i) => i.encode(env),
                        // encoding V128 is not yet supported by rustler
                        runtime::Value::V128(_) => {
                            (atoms::error(), "unable_to_convert_v128_type").encode(env)
                        }
                    })
                }
                (
                    atoms::invoke_callback(),
                    namespace_name.clone(),
                    import_name.clone(),
                    callback_params,
                    callback_token.clone(),
                )
                    .encode(env)
            });

            // Wait for the thread to start up.
            // let (lock, cvar) = callback_token.token;
            let mut result = callback_token.token.0.lock().unwrap();
            while result.is_none() {
                result = callback_token.token.1.wait(result).unwrap();
            }
            let result: Option<&(bool, Vec<runtime::Value>)> = result.as_ref();
            match result {
                Some((true, v)) => v.to_vec(),
                Some((false, v)) => v.to_vec(),
                None => unreachable!(),
            }
        },
    ))
}

// called from elixir, params
// * success: :ok | :error
//   indicates whether the call was successful or produced an elixir-error
// * results: [number]
//   return values of the elixir-callback - empty list when success-type is :error
pub fn receive_callback_result<'a>(env: Env<'a>, args: &[Term<'a>]) -> Result<Term<'a>, Error> {
    let token_resource: ResourceArc<CallbackTokenResource> = args[0].decode()?;
    let success = atoms::success() == args[1];
    let results = args[2].decode::<ListIterator>()?;

    //TODO: use real signature
    let signature = std::sync::Arc::new(FuncSig::new(vec![Type::I32], vec![Type::I32]));
    let results = match decode_function_param_terms(signature.returns(), results.collect()) {
        Ok(v) => v,
        Err(_reason) => {
            return Err(Error::Atom(
                "could not convert callback result param to expected return signature (`{}`)",
            ));
        }
    };

    let mut result = token_resource.token.0.lock().unwrap();
    *result = Some((success, results));
    token_resource.token.1.notify_one();

    Ok(atoms::ok().encode(env))
}
