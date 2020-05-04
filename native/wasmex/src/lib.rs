pub mod atoms;
pub mod environment;
pub mod functions;
pub mod instance;
pub mod memory;
pub mod namespace;
pub mod printable_term_type;

extern crate lazy_static;
#[macro_use]
extern crate rustler;

use rustler::{Env, Term};

rustler::init! {
    "Elixir.Wasmex.Native",
    [
        instance::new_from_bytes,
        instance::new_wasi_from_bytes,
        instance::function_export_exists,
        instance::call_exported_function,
        namespace::receive_callback_result,
        memory::from_instance,
        memory::bytes_per_element,
        memory::length,
        memory::grow,
        memory::get,
        memory::set,
        memory::read_binary,
        memory::write_binary,
    ],
    load = on_load
}

fn on_load(env: Env, _info: Term) -> bool {
    rustler::resource!(instance::InstanceResource, env);
    rustler::resource!(memory::MemoryResource, env);
    rustler::resource!(environment::CallbackTokenResource, env);
    true
}
