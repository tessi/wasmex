pub mod atoms;
pub mod caller;
pub mod environment;
pub mod functions;
pub mod instance;
pub mod memory;
pub mod module;
pub mod pipe;
pub mod printable_term_type;
pub mod store;

#[macro_use]
extern crate rustler;

use rustler::{Env, Term};

rustler::init! {
    "Elixir.Wasmex.Native",
    [
        instance::call_exported_function,
        instance::function_export_exists,
        instance::new,
        instance::receive_callback_result,
        memory::from_instance,
        memory::get_byte,
        memory::grow,
        memory::length,
        memory::read_binary,
        memory::set_byte,
        memory::write_binary,
        module::compile,
        module::exports,
        module::imports,
        module::name,
        module::serialize,
        module::unsafe_deserialize,
        pipe::create,
        pipe::read_binary,
        pipe::seek,
        pipe::size,
        pipe::write_binary,
        store::new,
        store::new_wasi,
    ],
    load = on_load
}

fn on_load(env: Env, _info: Term) -> bool {
    rustler::resource!(environment::CallbackTokenResource, env);
    rustler::resource!(environment::StoreOrCallerResource, env);
    rustler::resource!(instance::InstanceResource, env);
    rustler::resource!(memory::MemoryResource, env);
    rustler::resource!(module::ModuleResource, env);
    rustler::resource!(pipe::PipeResource, env);
    true
}
