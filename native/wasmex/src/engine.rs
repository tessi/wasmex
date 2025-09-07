use rustler::{Binary, Error, NifStruct, OwnedBinary, Resource, ResourceArc};
use std::ops::Deref;
use std::sync::{Mutex, LazyLock};
use wasmtime::{Config, Engine, WasmBacktraceDetails};

use crate::atoms;

pub static TOKIO_RUNTIME: LazyLock<tokio::runtime::Runtime> = LazyLock::new(|| {
    // Spawn <number of CPU cores> OS threads, fall back to `8` if detection fails
    let num_threads = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(8);

    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(num_threads)
        .thread_name("wasmex-async")
        .enable_all()
        .build()
        .expect("Failed to create Tokio runtime")
});

#[derive(NifStruct)]
#[module = "Wasmex.EngineConfig"]
pub struct ExEngineConfig {
    consume_fuel: bool,
    wasm_backtrace_details: bool,
    cranelift_opt_level: rustler::Atom,
    memory64: bool,
    wasm_component_model: bool,
    debug_info: bool,
}

#[rustler::resource_impl()]
impl Resource for EngineResource {}

pub struct EngineResource {
    pub inner: Mutex<Engine>,
}

#[rustler::nif(name = "engine_new")]
pub fn new(
    engine_config_ex: ExEngineConfig,
) -> Result<ResourceArc<EngineResource>, rustler::Error> {
    let config = engine_config(engine_config_ex);
    let engine = Engine::new(&config).map_err(|err| Error::Term(Box::new(err.to_string())))?;
    let resource = ResourceArc::new(EngineResource {
        inner: Mutex::new(engine),
    });

    Ok(resource)
}

#[rustler::nif(name = "engine_precompile_module", schedule = "DirtyCpu")]
pub fn precompile_module<'a>(
    env: rustler::Env<'a>,
    engine_resource: ResourceArc<EngineResource>,
    binary: Binary<'a>,
) -> Result<Binary<'a>, rustler::Error> {
    let engine: &Engine = &*(engine_resource.inner.lock().map_err(|e| {
        rustler::Error::Term(Box::new(format!("Could not unlock engine resource: {e}")))
    })?);
    let bytes = binary.as_slice();
    let serialized_module = engine.precompile_module(bytes).map_err(|err| {
        rustler::Error::Term(Box::new(format!("Could not precompile module: {err}")))
    })?;
    let mut binary = OwnedBinary::new(serialized_module.len())
        .ok_or_else(|| rustler::Error::Term(Box::new("not enough memory")))?;
    binary.copy_from_slice(&serialized_module);
    Ok(binary.release(env))
}

pub(crate) fn engine_config(engine_config: ExEngineConfig) -> Config {
    let backtrace_details = match engine_config.wasm_backtrace_details {
        true => WasmBacktraceDetails::Enable,
        false => WasmBacktraceDetails::Disable,
    };
    let cranelift_opt_level = if engine_config.cranelift_opt_level == atoms::speed() {
        wasmtime::OptLevel::Speed
    } else if engine_config.cranelift_opt_level == atoms::speed_and_size() {
        wasmtime::OptLevel::SpeedAndSize
    } else {
        wasmtime::OptLevel::None
    };

    let mut config = Config::new();
    config.consume_fuel(engine_config.consume_fuel);
    config.wasm_backtrace_details(backtrace_details);
    config.cranelift_opt_level(cranelift_opt_level);
    config.wasm_memory64(engine_config.memory64);
    config.wasm_component_model(engine_config.wasm_component_model);
    config.debug_info(engine_config.debug_info);

    config
}

pub(crate) fn unwrap_engine(
    engine_resource: ResourceArc<EngineResource>,
) -> Result<Engine, rustler::Error> {
    let engine: Engine = engine_resource
        .deref()
        .inner
        .lock()
        .map_err(|e| {
            rustler::Error::Term(Box::new(format!(
                "Could not unlock engine resource as the mutex was poisoned: {e}"
            )))
        })?
        .clone();
    Ok(engine)
}
