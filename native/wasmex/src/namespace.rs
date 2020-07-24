//! Namespace API of an WebAssembly instance.

use rustler::{
    resource::ResourceArc, types::atom::is_truthy, types::ListIterator, Encoder, Env as RustlerEnv,
    Error, Term,
};

use crate::{atoms, environment::CallbackTokenResource, instance::decode_function_param_terms};

// called from elixir, params
// * callback_token
// * success: :ok | :error
//   indicates whether the call was successful or produced an elixir-error
// * results: [number]
//   return values of the elixir-callback - empty list when success-type is :error
pub fn receive_callback_result<'a>(
    env: RustlerEnv<'a>,
    args: &[Term<'a>],
) -> Result<Term<'a>, Error> {
    let token_resource: ResourceArc<CallbackTokenResource> = args[0].decode()?;
    let success = is_truthy(args[1]);

    let results = if success {
        let result_list = args[2].decode::<ListIterator>()?;
        let return_types = token_resource.token.return_types.clone();
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

    let mut result = token_resource.token.return_values.lock().unwrap();
    *result = Some((success, results));
    token_resource.token.continue_signal.notify_one();

    Ok(atoms::ok().encode(env))
}
