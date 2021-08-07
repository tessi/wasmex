pub mod atoms;
pub mod environment;
pub mod functions;
pub mod instance;
pub mod memory;
pub mod module;
pub mod namespace;
pub mod pipe;
pub mod printable_term_type;

extern crate lazy_static;
#[macro_use]
extern crate rustler;

use rustler::{Env, Term};

rustler::init! {
    "Elixir.Wasmex.Native",
    [
        instance::call_exported_function,
        instance::function_export_exists,
        instance::new_wasi,
        instance::new,
        memory::bytes_per_element,
        memory::from_instance,
        memory::get,
        memory::grow,
        memory::length,
        memory::read_binary,
        memory::set,
        memory::write_binary,
        module::compile,
        module::exports,
        module::imports,
        module::name,
        module::serialize,
        module::set_name,
        module::unsafe_deserialize,
        namespace::receive_callback_result,
        pipe::create,
        pipe::read_binary,
        pipe::set_len,
        pipe::size,
        pipe::write_binary
    ],
    load = on_load
}

fn on_load(env: Env, _info: Term) -> bool {
    rustler::resource!(environment::CallbackTokenResource, env);
    rustler::resource!(instance::InstanceResource, env);
    rustler::resource!(memory::MemoryResource, env);
    rustler::resource!(module::ModuleResource, env);
    rustler::resource!(pipe::PipeResource, env);
    true
}
