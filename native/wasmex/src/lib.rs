pub mod atoms;
pub mod functions;
pub mod instance;
pub mod memory;
pub mod namespace;
pub mod printable_term_type;

extern crate lazy_static;
#[macro_use]
extern crate rustler;

use rustler::{Env, Term};

rustler::rustler_export_nifs! {
    "Elixir.Wasmex.Native",
    [
        ("instance_new_from_bytes", 2, instance::new_from_bytes),
        ("instance_function_export_exists", 2, instance::function_export_exists),
        ("instance_call_exported_function", 4, instance::call_exported_function),
        ("namespace_receive_callback_result", 3, namespace::receive_callback_result),
        ("memory_from_instance", 1, memory::from_instance),
        ("memory_bytes_per_element", 3, memory::bytes_per_element),
        ("memory_length", 3, memory::length),
        ("memory_grow", 4, memory::grow),
        ("memory_get", 4, memory::get),
        ("memory_set", 5, memory::set),
        ("memory_read_binary", 5, memory::read_binary),
        ("memory_write_binary", 5, memory::write_binary),
    ],
    Some(on_load)
}

fn on_load(env: Env, _info: Term) -> bool {
    resource_struct_init!(instance::InstanceResource, env);
    resource_struct_init!(memory::MemoryResource, env);
    resource_struct_init!(namespace::CallbackTokenResource, env);
    true
}
