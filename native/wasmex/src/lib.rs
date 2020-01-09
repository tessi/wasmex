pub mod atoms;
pub mod instance;

#[macro_use]
extern crate rustler;

use rustler::{Env, Term};

rustler::rustler_export_nifs! {
    "Elixir.Wasmex.Native",
    [
        ("instance_new_from_bytes", 1, instance::new_from_bytes)
    ],
    Some(on_load)
}

fn on_load(env: Env, _info: Term) -> bool {
    resource_struct_init!(instance::InstanceResource, env);
    true
}