pub mod atoms;
pub mod caller;
pub mod engine;
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
        engine::new,
        engine::precompile_module,
        instance::read_global,
        instance::call_exported_function,
        instance::function_export_exists,
        instance::new,
        instance::receive_callback_result,
        memory::from_instance,
        memory::get_byte,
        memory::grow,
        memory::read_binary,
        memory::set_byte,
        memory::size,
        memory::write_binary,
        module::compile,
        module::exports,
        module::imports,
        module::name,
        module::serialize,
        module::unsafe_deserialize,
        pipe::new,
        pipe::read_binary,
        pipe::seek,
        pipe::size,
        pipe::write_binary,
        store::get_fuel,
        store::set_fuel,
        store::new_wasi,
        store::new,
    ],
    load = on_load
}

fn on_load(env: Env, _info: Term) -> bool {
    rustler::resource!(engine::EngineResource, env);
    rustler::resource!(environment::CallbackTokenResource, env);
    rustler::resource!(instance::InstanceResource, env);
    rustler::resource!(memory::MemoryResource, env);
    rustler::resource!(module::ModuleResource, env);
    rustler::resource!(pipe::PipeResource, env);
    rustler::resource!(store::StoreOrCallerResource, env);
    true
}
