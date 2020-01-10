pub mod atoms;
pub mod instance;
pub mod printable_term_type;
pub mod functions;

extern crate lazy_static;
#[macro_use]
extern crate rustler;

use rustler::{Env, Term};

rustler::rustler_export_nifs! {
    "Elixir.Wasmex.Native",
    [
        ("instance_new_from_bytes", 1, instance::new_from_bytes),
        ("instance_function_export_exists", 2, instance::function_export_exists),
        ("instance_call_exported_function", 3, instance::call_exported_function),
    ],
    Some(on_load)
}

fn on_load(env: Env, _info: Term) -> bool {
    resource_struct_init!(instance::InstanceResource, env);
    true
}