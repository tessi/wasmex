//! Namespace API of an WebAssembly instance.

use rustler::{resource::ResourceArc, types::ListIterator, Error, NifResult};

use crate::{atoms, environment::CallbackTokenResource, instance::decode_function_param_terms};

// called from elixir, params
// * callback_token
// * success: :ok | :error
//   indicates whether the call was successful or produced an elixir-error
// * results: [number]
//   return values of the elixir-callback - empty list when success-type is :error
#[rustler::nif(name = "namespace_receive_callback_result")]
pub fn receive_callback_result(
    token_resource: ResourceArc<CallbackTokenResource>,
    success: bool,
    result_list: ListIterator,
) -> NifResult<rustler::Atom> {
    let results = if success {
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

    Ok(atoms::ok())
}
