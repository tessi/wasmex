use lazy_static::lazy_static;
use rustler::{Binary, Error, NifStruct, OwnedBinary, Resource, ResourceArc};
use std::ops::Deref;
use std::sync::{Arc, Mutex, RwLock};
use std::time::Duration;
use tokio::runtime::Runtime;
use wasmtime::{Config, Engine, WasmBacktraceDetails};

use crate::atoms;

// Global Tokio runtime for async operations
// This creates a multi-threaded runtime that uses lightweight tasks (green threads)
// NOT OS threads per task - many tasks are multiplexed onto a small thread pool
lazy_static! {
    pub static ref TOKIO_RUNTIME: Arc<Runtime> = {
        // Use all available CPU cores for optimal performance
        // This allows Tokio to efficiently schedule async tasks across all cores
        let num_threads = std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(8);  // Fallback to 8 if detection fails

        Arc::new(
            tokio::runtime::Builder::new_multi_thread()
                .worker_threads(num_threads)
                .thread_name("wasmex-async")
                .enable_all()
                .build()
                .expect("Failed to create Tokio runtime")
        )
    };
    
    // Track engines with epoch interruption enabled
    pub static ref EPOCH_ENGINES: RwLock<Vec<EpochEngine>> = RwLock::new(Vec::new());
}

// Structure to track engines with epoch interruption
pub struct EpochEngine {
    pub engine: Engine,
    pub interval_ms: u64,
}

#[derive(NifStruct)]
#[module = "Wasmex.EngineConfig"]
pub struct ExEngineConfig {
    consume_fuel: bool,
    wasm_backtrace_details: bool,
    cranelift_opt_level: rustler::Atom,
    memory64: bool,
    wasm_component_model: bool,
    debug_info: bool,
    epoch_interruption: bool,
    epoch_interval_ms: u64,
}

#[rustler::resource_impl()]
impl Resource for EngineResource {}

pub struct EngineResource {
    pub inner: Mutex<Engine>,
}

#[rustler::nif(name = "engine_new")]
pub fn new(engine_config_ex: ExEngineConfig) -> Result<ResourceArc<EngineResource>, rustler::Error> {
    let epoch_interruption = engine_config_ex.epoch_interruption;
    let epoch_interval_ms = engine_config_ex.epoch_interval_ms;
    let config = engine_config(engine_config_ex);
    let engine = Engine::new(&config).map_err(|err| Error::Term(Box::new(err.to_string())))?;
    
    // If epoch interruption is enabled, start the epoch ticker
    if epoch_interruption {
        let engine_clone = engine.clone();
        
        // Add to global epoch engines list
        EPOCH_ENGINES.write().unwrap().push(EpochEngine {
            engine: engine.clone(),
            interval_ms: epoch_interval_ms,
        });
        
        // Start the epoch ticker in the Tokio runtime
        TOKIO_RUNTIME.spawn(async move {
            let mut interval = tokio::time::interval(Duration::from_millis(epoch_interval_ms));
            loop {
                interval.tick().await;
                engine_clone.increment_epoch();
            }
        });
    }
    
    let resource = ResourceArc::new(EngineResource {
        inner: Mutex::new(engine),
    });
    Ok(resource)
}

#[rustler::nif(name = "engine_precompile_module")]
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
    
    // Configure epoch-based interruption
    if engine_config.epoch_interruption {
        config.epoch_interruption(true);
    }
    
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
