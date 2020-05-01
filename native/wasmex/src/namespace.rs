//! Namespace API of an WebAssembly instance.

use rustler::{
    resource::ResourceArc, types::atom::is_truthy, types::tuple, types::ListIterator, Atom,
    Encoder, Env, Error, MapIterator, OwnedEnv, Term,
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
        create_import(&mut namespace, &namespace_name, &name, import)?;
    }
    Ok(namespace)
}

fn create_import(
    namespace: &mut Namespace,
    namespace_name: &String,
    import_name: &String,
    definition: Term,
) -> Result<(), Error> {
    let import_tuple = tuple::get_tuple(definition)?;

    let import_type = import_tuple
        .get(0)
        .ok_or_else(|| Error::Atom("missing_import_type"))?;
    let import_type =
        Atom::from_term(*import_type).map_err(|_| Error::Atom("import type must be an atom"))?;

    if atoms::__fn__().eq(&import_type) {
        let import =
            create_imported_function(namespace_name.clone(), import_name.clone(), definition)?;
        namespace.insert(import_name, import);
        return Ok(());
    }

    return Err(Error::Atom("unknown import type"));
}

fn term_to_arg_type(term: Term) -> Result<Type, Error> {
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
        Err(_) => Err(Error::Atom("not_an_atom")),
    }
}

// Creates a wrapper function used in a WASM import object.
// The `definition` term must contain a function signature matching the signature if the WASM import.
// Once the imported function is called during WASM execution, the following happens:
// 1. the rust wrapper we define here is called
// 2. it creates a callback token containing a Mutex for storing the call result and a Condvar
// 3. the rust wrapper sends an :invoke_callback message to elixir containing the token and call params
// 4. the Wasmex module receive that call in elixir-land and executes the actual elixir callback
// 5. after the callback finished execution, return values are send back to Rust via `receive_callback_result`
// 6. `receive_callback_result` saves the return values in the callback tokens mutex and signals the condvar,
//    so that the original wrapper function can continue code execution
fn create_imported_function(
    namespace_name: String,
    import_name: String,
    definition: Term,
) -> Result<DynamicFunc<'static>, Error> {
    let pid = definition.get_env().pid();

    let import_tuple = tuple::get_tuple(definition)?;

    let param_term = import_tuple
        .get(1)
        .ok_or_else(|| Error::Atom("missing_import_params"))?;
    let results_term = import_tuple
        .get(2)
        .ok_or_else(|| Error::Atom("missing_import_results"))?;

    let params_signature = param_term
        .decode::<ListIterator>()?
        .map(|term| term_to_arg_type(term))
        .collect::<Result<Vec<Type>, _>>()?;

    let results_signature = results_term
        .decode::<ListIterator>()?
        .map(|term| term_to_arg_type(term))
        .collect::<Result<Vec<Type>, _>>()?;

    let signature = Arc::new(FuncSig::new(
        params_signature.clone(),
        results_signature.clone(),
    ));

    Ok(DynamicFunc::new(
        signature,
        move |_ctx: &mut Ctx, params: &[Value]| -> Vec<runtime::Value> {
            let callback_token = ResourceArc::new(CallbackTokenResource {
                token: (Mutex::new(None), Condvar::new(), results_signature.clone()),
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
                // Callback context will contain memory, globals, tables etc later.
                // This will allow Elixir callback to operate on these objects.
                let callback_context = Term::map_new(env);
                (
                    atoms::invoke_callback(),
                    namespace_name.clone(),
                    import_name.clone(),
                    callback_context,
                    callback_params,
                    callback_token.clone(),
                )
                    .encode(env)
            });

            // Wait for the thread to start up - `receive_callback_result` is responsible for that.
            let mut result = callback_token.token.0.lock().unwrap();
            while result.is_none() {
                result = callback_token.token.1.wait(result).unwrap();
            }

            let result: &(bool, Vec<runtime::Value>) = result
                .as_ref()
                .expect("expect callback token to contain a result");
            match result {
                (true, v) => v.to_vec(),
                (false, _) => panic!("the elixir callback threw an exception"),
            }
        },
    ))
}

// called from elixir, params
// * callback_token
// * success: :ok | :error
//   indicates whether the call was successful or produced an elixir-error
// * results: [number]
//   return values of the elixir-callback - empty list when success-type is :error
pub fn receive_callback_result<'a>(env: Env<'a>, args: &[Term<'a>]) -> Result<Term<'a>, Error> {
    let token_resource: ResourceArc<CallbackTokenResource> = args[0].decode()?;
    let success = is_truthy(args[1]);

    let results = if success {
        let result_list = args[2].decode::<ListIterator>()?;
        let return_types = token_resource.token.2.clone();
        match decode_function_param_terms(&return_types, result_list.collect()) {
            Ok(v) => v,
            Err(_reason) => {
                return Err(Error::Atom(
                    "could not convert callback result param to expected return signature",
                ));
            }
        }
    } else {
        vec![]
    };

    let mut result = token_resource.token.0.lock().unwrap();
    *result = Some((success, results));
    token_resource.token.1.notify_one();

    Ok(atoms::ok().encode(env))
}
