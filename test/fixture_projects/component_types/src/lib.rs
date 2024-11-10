#[allow(warnings)]
mod bindings;

use bindings::Guest;
use paste::paste;

macro_rules! id_function {
    ($wasm_ty:ident, $rust_ty:ty) => {
        paste! {
            fn [<id_ $wasm_ty>](v: $rust_ty) -> $rust_ty {
                v
            }
        }
    };
}

struct Component;
impl Guest for Component {
    id_function!(bool, bool);
}

bindings::export!(Component with_types_in bindings);
