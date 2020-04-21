//! Namespace API of an WebAssembly instance.

use rustler::{
    resource::ResourceArc, types::ListIterator, Encoder, Env, Error, MapIterator, OwnedEnv, Term,
};
use std::sync::{Condvar, Mutex};
use wasmer_runtime::{self as runtime};
use wasmer_runtime_core::{
    import::Namespace, typed_func::DynamicFunc, types::FuncSig, types::Type, types::Value, vm::Ctx,
};

use crate::{atoms, instance::decode_function_param_terms};

pub struct CallbackTokenResource {
    pub token: (Mutex<Option<(bool, Vec<runtime::Value>)>>, Condvar),
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
            create_imported_function(namespace_name.clone(), name, import),
        );
    }
    Ok(namespace)
}

fn create_imported_function(
    namespace_name: String,
    import_name: String,
    definition: Term,
) -> DynamicFunc<'static> {
    let pid = definition.get_env().pid();
    // let signature = args[2];
    // let param_types = signature.map_get(atoms::params().encode(env));
    // let result_types = signature.map_get(atoms::results().encode(env)); // TODO: copy result_types into callback_token
    // TODO: build a real signature
    let signature = std::sync::Arc::new(FuncSig::new(vec![Type::I32, Type::I32], vec![Type::I32]));

    DynamicFunc::new(
        signature,
        move |_ctx: &mut Ctx, params: &[Value]| -> Vec<runtime::Value> {
            let callback_token = ResourceArc::new(CallbackTokenResource {
                token: (Mutex::new(None), Condvar::new()),
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
    )
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
