use crate::{
    caller::{get_caller, get_caller_mut},
    engine::{unwrap_engine, EngineResource},
    pipe::{Pipe, PipeResource},
};
use rustler::{Error, NifStruct, ResourceArc};
use std::{collections::HashMap, sync::Mutex};
use wasi_common::{sync::WasiCtxBuilder, WasiCtx};
use wasmtime::{
    AsContext, AsContextMut, Engine, Store, StoreContext, StoreContextMut, StoreLimits,
    StoreLimitsBuilder,
};

#[derive(Debug, NifStruct)]
#[module = "Wasmex.Wasi.PreopenOptions"]
pub struct ExWasiPreopenOptions {
    path: String,
    alias: Option<String>,
}

#[derive(NifStruct)]
#[module = "Wasmex.Pipe"]
pub struct ExPipe {
    resource: ResourceArc<PipeResource>,
}

#[derive(NifStruct)]
#[module = "Wasmex.Wasi.WasiOptions"]
pub struct ExWasiOptions {
    args: Vec<String>,
    env: HashMap<String, String>,
    stderr: Option<ExPipe>,
    stdin: Option<ExPipe>,
    stdout: Option<ExPipe>,
    preopen: Vec<ExWasiPreopenOptions>,
}

#[derive(NifStruct)]
#[module = "Wasmex.StoreLimits"]
pub struct ExStoreLimits {
    memory_size: Option<usize>,
    table_elements: Option<u32>,
    instances: Option<usize>,
    tables: Option<usize>,
    memories: Option<usize>,
}

impl ExStoreLimits {
    pub fn to_wasmtime(&self) -> StoreLimits {
        let limits = StoreLimitsBuilder::new();

        let limits = if let Some(memory_size) = self.memory_size {
            limits.memory_size(memory_size)
        } else {
            limits
        };

        let limits = if let Some(table_elements) = self.table_elements {
            limits.table_elements(table_elements)
        } else {
            limits
        };

        let limits = if let Some(instances) = self.instances {
            limits.instances(instances)
        } else {
            limits
        };

        let limits = if let Some(tables) = self.tables {
            limits.tables(tables)
        } else {
            limits
        };

        let limits = if let Some(memories) = self.memories {
            limits.memories(memories)
        } else {
            limits
        };

        limits.build()
    }
}

pub struct StoreData {
    pub(crate) wasi: Option<WasiCtx>,
    pub(crate) limits: StoreLimits,
}

pub enum StoreOrCaller {
    Store(Store<StoreData>),
    Caller(i32),
}

pub struct StoreOrCallerResource {
    pub inner: Mutex<StoreOrCaller>,
}

#[rustler::resource_impl()]
impl rustler::Resource for StoreOrCallerResource {}

impl StoreOrCaller {
    pub fn engine(&self) -> &Engine {
        match self {
            StoreOrCaller::Store(store) => store.engine(),
            StoreOrCaller::Caller(token) => get_caller(token).unwrap().engine(),
        }
    }

    pub fn data(&self) -> &StoreData {
        match self {
            StoreOrCaller::Store(store) => store.data(),
            StoreOrCaller::Caller(token) => get_caller(token).unwrap().data(),
        }
    }
}

impl AsContext for StoreOrCaller {
    type Data = StoreData;

    fn as_context(&self) -> StoreContext<'_, Self::Data> {
        match self {
            StoreOrCaller::Store(store) => store.as_context(),
            StoreOrCaller::Caller(token) => get_caller(token).unwrap().as_context(),
        }
    }
}

impl AsContextMut for StoreOrCaller {
    fn as_context_mut(&mut self) -> StoreContextMut<'_, Self::Data> {
        match self {
            StoreOrCaller::Store(store) => store.as_context_mut(),
            StoreOrCaller::Caller(token) => get_caller_mut(token).unwrap().as_context_mut(),
        }
    }
}

#[rustler::nif(name = "store_new")]
pub fn new(
    limits: Option<ExStoreLimits>,
    engine_resource: ResourceArc<EngineResource>,
) -> Result<ResourceArc<StoreOrCallerResource>, rustler::Error> {
    let engine = unwrap_engine(engine_resource)?;
    let limits = if let Some(limits) = limits {
        limits.to_wasmtime()
    } else {
        StoreLimits::default()
    };
    let mut store = Store::new(&engine, StoreData { wasi: None, limits });
    store.limiter(|state| &mut state.limits);
    let resource = ResourceArc::new(StoreOrCallerResource {
        inner: Mutex::new(StoreOrCaller::Store(store)),
    });
    Ok(resource)
}

#[rustler::nif(name = "store_new_wasi")]
pub fn new_wasi(
    options: ExWasiOptions,
    limits: Option<ExStoreLimits>,
    engine_resource: ResourceArc<EngineResource>,
) -> Result<ResourceArc<StoreOrCallerResource>, rustler::Error> {
    let wasi_env = &options
        .env
        .iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect::<Vec<_>>();

    let mut builder = WasiCtxBuilder::new();

    builder
        .args(&options.args)
        .map_err(|err| Error::Term(Box::new(err.to_string())))?
        .envs(wasi_env)
        .map_err(|err| Error::Term(Box::new(err.to_string())))?;

    add_pipe(options.stdin, &mut builder, |pipe, builder| {
        builder.stdin(pipe);
    })?;
    add_pipe(options.stdout, &mut builder, |pipe, builder| {
        builder.stdout(pipe);
    })?;
    add_pipe(options.stderr, &mut builder, |pipe, builder| {
        builder.stderr(pipe);
    })?;
    wasi_preopen_directories(options.preopen, &mut builder)?;
    let wasi_ctx = builder.build();

    let engine = unwrap_engine(engine_resource)?;
    let limits = if let Some(limits) = limits {
        limits.to_wasmtime()
    } else {
        StoreLimits::default()
    };
    let mut store = Store::new(
        &engine,
        StoreData {
            wasi: Some(wasi_ctx),
            limits,
        },
    );
    store.limiter(|state| &mut state.limits);
    let resource = ResourceArc::new(StoreOrCallerResource {
        inner: Mutex::new(StoreOrCaller::Store(store)),
    });
    Ok(resource)
}

#[rustler::nif(name = "store_or_caller_set_fuel")]
pub fn set_fuel(
    store_or_caller_resource: ResourceArc<StoreOrCallerResource>,
    fuel: u64,
) -> Result<(), rustler::Error> {
    let store_or_caller: &mut StoreOrCaller =
        &mut *(store_or_caller_resource.inner.try_lock().map_err(|e| {
            rustler::Error::Term(Box::new(format!("Could not unlock store resource: {e}")))
        })?);
    match store_or_caller {
        StoreOrCaller::Store(store) => store.set_fuel(fuel),
        StoreOrCaller::Caller(token) => get_caller_mut(token)
            .ok_or_else(|| {
                rustler::Error::Term(Box::new(
                    "Caller is not valid. Only use a caller within its own function scope.",
                ))
            })
            .map(|c| c.set_fuel(fuel))?,
    }
    .map_err(|e| rustler::Error::Term(Box::new(format!("Could not set fuel: {e}"))))
}

#[rustler::nif(name = "store_or_caller_get_fuel")]
pub fn get_fuel(
    store_or_caller_resource: ResourceArc<StoreOrCallerResource>,
) -> Result<u64, rustler::Error> {
    let store_or_caller: &mut StoreOrCaller =
        &mut *(store_or_caller_resource.inner.try_lock().map_err(|e| {
            rustler::Error::Term(Box::new(format!("Could not unlock store resource: {e}")))
        })?);
    match store_or_caller {
        StoreOrCaller::Store(store) => store.get_fuel(),
        StoreOrCaller::Caller(token) => get_caller_mut(token)
            .ok_or_else(|| {
                rustler::Error::Term(Box::new(
                    "Caller is not valid. Only use a caller within its own function scope.",
                ))
            })
            .map(|c| c.get_fuel())?,
    }
    .map_err(|e| rustler::Error::Term(Box::new(format!("Could not get fuel: {e}"))))
}

fn add_pipe(
    pipe: Option<ExPipe>,
    builder: &mut WasiCtxBuilder,
    f: fn(Box<Pipe>, &mut WasiCtxBuilder) -> (),
) -> Result<(), rustler::Error> {
    if let Some(ExPipe { resource }) = pipe {
        let pipe = resource.pipe.lock().map_err(|_e| {
            rustler::Error::Term(Box::new(
                "Could not unlock resource as the mutex was poisoned.",
            ))
        })?;
        let pipe = Box::new(pipe.clone());
        f(pipe, builder);
    }
    Ok(())
}

fn wasi_preopen_directories(
    preopens: Vec<ExWasiPreopenOptions>,
    builder: &mut WasiCtxBuilder,
) -> Result<(), rustler::Error> {
    preopens
        .iter()
        .try_fold((), |_acc, preopen| preopen_directory(builder, preopen))
}

fn preopen_directory(
    builder: &mut WasiCtxBuilder,
    preopen: &ExWasiPreopenOptions,
) -> Result<(), Error> {
    let path = &preopen.path;
    let dir = wasi_common::sync::Dir::from_std_file(
        std::fs::File::open(path).map_err(|err| rustler::Error::Term(Box::new(err.to_string())))?,
    );
    let guest_path = preopen.alias.as_ref().unwrap_or(path);
    builder
        .preopened_dir(dir, guest_path)
        .map_err(|err| Error::Term(Box::new(err.to_string())))?;
    Ok(())
}
