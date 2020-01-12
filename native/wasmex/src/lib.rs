pub mod atoms;
pub mod functions;
pub mod instance;
pub mod memory;
pub mod printable_term_type;

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
        ("memory_from_instance", 3, memory::from_instance),
        ("memory_bytes_per_element", 1, memory::bytes_per_element),
        ("memory_length", 1, memory::length),
        ("memory_grow", 2, memory::grow),
        ("memory_get", 2, memory::get),
        ("memory_set", 3, memory::set),
    ],
    Some(on_load)
}

fn on_load(env: Env, _info: Term) -> bool {
    resource_struct_init!(instance::InstanceResource, env);
    resource_struct_init!(memory::MemoryResource, env);
    true
}
