use crate::{
    async_reply::{submit_error, AsyncReply},
    caller::{CallbackSession, CallerCommand},
    engine::{unwrap_engine_and_ticker, EngineResource},
    pipe::{Pipe, PipeResource},
    store_executor::{InterruptState, StoreExecutor},
};
use rustler::{Atom, Error, NifStruct, ResourceArc, Term};
use std::{
    collections::HashMap,
    sync::{atomic::AtomicBool, Arc, Mutex},
};
use wasmtime::{Engine, Store, StoreLimits, StoreLimitsBuilder};
use wasmtime_wasi::{
    p1::WasiP1Ctx, DirPerms, FilePerms, ResourceTable, WasiCtx, WasiCtxBuilder, WasiView,
};
use wasmtime_wasi_http::{
    p2::{WasiHttpCtxView, WasiHttpView},
    WasiHttpCtx,
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
#[module = "Wasmex.Wasi.WasiP2Options"]
pub struct ExWasiP2Options {
    args: Vec<String>,
    env: HashMap<String, String>,
    inherit_stdin: bool,
    inherit_stdout: bool,
    inherit_stderr: bool,
    allow_http: bool,
}

#[derive(NifStruct)]
#[module = "Wasmex.StoreLimits"]
pub struct ExStoreLimits {
    memory_size: Option<usize>,
    table_elements: Option<usize>,
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
    pub(crate) wasi: Option<WasiP1Ctx>,
    pub(crate) limits: StoreLimits,
    pub(crate) interrupt_requested: Arc<AtomicBool>,
}

pub struct ComponentStoreData {
    pub(crate) ctx: Option<WasiCtx>,
    pub(crate) http: Option<WasiHttpCtx>,
    pub(crate) limits: StoreLimits,
    pub(crate) table: ResourceTable,
    pub(crate) interrupt_requested: Arc<AtomicBool>,
}

impl InterruptState for StoreData {
    fn interrupt_requested(&self) -> &AtomicBool {
        &self.interrupt_requested
    }
}

impl InterruptState for ComponentStoreData {
    fn interrupt_requested(&self) -> &AtomicBool {
        &self.interrupt_requested
    }
}

impl WasiHttpView for ComponentStoreData {
    fn http(&mut self) -> WasiHttpCtxView<'_> {
        WasiHttpCtxView {
            ctx: self.http.as_mut().expect("WasiHttpCtx is not set"),
            table: &mut self.table,
            hooks: Default::default(),
        }
    }
}

impl WasiView for ComponentStoreData {
    fn ctx(&mut self) -> wasmtime_wasi::WasiCtxView<'_> {
        let ctx = self.ctx.as_mut().expect("WasiCtx is not set");
        wasmtime_wasi::WasiCtxView {
            ctx,
            table: &mut self.table,
        }
    }
}

pub enum StoreOrCaller {
    Store(StoreExecutor<StoreData>),
    Caller(CallbackSession),
}

pub struct StoreOrCallerResource {
    pub inner: Mutex<StoreOrCaller>,
}

pub struct ComponentStoreResource {
    pub inner: Mutex<StoreExecutor<ComponentStoreData>>,
}

#[rustler::resource_impl()]
impl rustler::Resource for ComponentStoreResource {}

#[rustler::resource_impl()]
impl rustler::Resource for StoreOrCallerResource {}

impl StoreOrCaller {
    pub fn engine(&self) -> &Engine {
        match self {
            StoreOrCaller::Store(store) => store.engine(),
            StoreOrCaller::Caller(session) => session.engine(),
        }
    }
}

impl StoreOrCallerResource {
    pub fn target(&self) -> Result<StoreTarget, rustler::Error> {
        let inner = self.inner.lock().map_err(|error| {
            rustler::Error::Term(Box::new(format!(
                "Could not unlock store resource: {error}"
            )))
        })?;
        match &*inner {
            StoreOrCaller::Store(executor) => Ok(StoreTarget::Executor(executor.clone())),
            StoreOrCaller::Caller(session) => Ok(StoreTarget::Caller(session.clone())),
        }
    }
}

impl ComponentStoreResource {
    pub fn executor(&self) -> Result<StoreExecutor<ComponentStoreData>, rustler::Error> {
        self.inner
            .lock()
            .map(|executor| executor.clone())
            .map_err(|error| {
                rustler::Error::Term(Box::new(format!(
                    "Could not unlock component store resource: {error}"
                )))
            })
    }
}

pub enum StoreTarget {
    Executor(StoreExecutor<StoreData>),
    Caller(CallbackSession),
}

#[rustler::nif(name = "store_new")]
pub fn new(
    limits: Option<ExStoreLimits>,
    engine_resource: ResourceArc<EngineResource>,
) -> Result<ResourceArc<StoreOrCallerResource>, rustler::Error> {
    let (engine, ticker) = unwrap_engine_and_ticker(engine_resource)?;
    let limits = if let Some(limits) = limits {
        limits.to_wasmtime()
    } else {
        StoreLimits::default()
    };
    let mut store = Store::new(
        &engine,
        StoreData {
            wasi: None,
            limits,
            interrupt_requested: Arc::new(AtomicBool::new(false)),
        },
    );
    store.limiter(|state| &mut state.limits);
    let resource = ResourceArc::new(StoreOrCallerResource {
        inner: Mutex::new(StoreOrCaller::Store(StoreExecutor::new_async(
            store, ticker,
        ))),
    });
    Ok(resource)
}

#[rustler::nif(name = "component_store_new")]
pub fn component_store_new(
    limits: Option<ExStoreLimits>,
    engine_resource: ResourceArc<EngineResource>,
) -> Result<ResourceArc<ComponentStoreResource>, rustler::Error> {
    let (engine, ticker) = unwrap_engine_and_ticker(engine_resource)?;
    let limits = if let Some(limits) = limits {
        limits.to_wasmtime()
    } else {
        StoreLimits::default()
    };
    let mut store = Store::new(
        &engine,
        ComponentStoreData {
            http: None,
            ctx: None,
            limits,
            table: wasmtime_wasi::ResourceTable::new(),
            interrupt_requested: Arc::new(AtomicBool::new(false)),
        },
    );
    store.limiter(|state| &mut state.limits);
    let resource: ResourceArc<ComponentStoreResource> = ResourceArc::new(ComponentStoreResource {
        inner: Mutex::new(StoreExecutor::new_async(store, ticker)),
    });
    Ok(resource)
}

#[rustler::nif(name = "component_store_new_wasi")]
pub fn component_store_new_wasi(
    options: ExWasiP2Options,
    limits: Option<ExStoreLimits>,
    engine_resource: ResourceArc<EngineResource>,
) -> Result<ResourceArc<ComponentStoreResource>, rustler::Error> {
    let wasi_env = &options
        .env
        .iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect::<Vec<_>>();
    let mut wasi_ctx_builder = wasmtime_wasi::WasiCtxBuilder::new();
    wasi_ctx_builder.args(&options.args).envs(wasi_env);

    if options.inherit_stdin {
        wasi_ctx_builder.inherit_stdin();
    }

    if options.inherit_stdout {
        wasi_ctx_builder.inherit_stdout();
    }

    if options.inherit_stderr {
        wasi_ctx_builder.inherit_stderr();
    }

    if options.allow_http {
        wasi_ctx_builder
            .inherit_network()
            .allow_ip_name_lookup(true);
    }

    let (engine, ticker) = unwrap_engine_and_ticker(engine_resource)?;
    let limits = if let Some(limits) = limits {
        limits.to_wasmtime()
    } else {
        StoreLimits::default()
    };

    let http_option = if options.allow_http {
        Some(WasiHttpCtx::new())
    } else {
        None
    };

    let mut store = Store::new(
        &engine,
        ComponentStoreData {
            ctx: Some(wasi_ctx_builder.build()),
            limits,
            http: http_option,
            table: wasmtime_wasi::ResourceTable::new(),
            interrupt_requested: Arc::new(AtomicBool::new(false)),
        },
    );
    store.limiter(|state| &mut state.limits);
    let resource: ResourceArc<ComponentStoreResource> = ResourceArc::new(ComponentStoreResource {
        inner: Mutex::new(StoreExecutor::new_async(store, ticker)),
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

    builder.args(&options.args).envs(wasi_env);

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
    let wasi_ctx = builder.build_p1();

    let (engine, ticker) = unwrap_engine_and_ticker(engine_resource)?;
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
            interrupt_requested: Arc::new(AtomicBool::new(false)),
        },
    );
    store.limiter(|state| &mut state.limits);
    let resource = ResourceArc::new(StoreOrCallerResource {
        inner: Mutex::new(StoreOrCaller::Store(StoreExecutor::new_async(
            store, ticker,
        ))),
    });
    Ok(resource)
}

#[rustler::nif(name = "store_or_caller_set_fuel")]
pub fn set_fuel(
    store_or_caller_resource: ResourceArc<StoreOrCallerResource>,
    fuel: u64,
    from: Term,
) -> Result<Atom, rustler::Error> {
    let reply = AsyncReply::new(from)?;
    match store_or_caller_resource.target()? {
        StoreTarget::Executor(executor) => {
            let submit_reply = AsyncReply::new(from)?;
            if let Err(error) = executor.submit(move |mut store| async move {
                match store.set_fuel(fuel) {
                    Ok(()) => reply.send(()),
                    Err(error) => reply.send_error(format!("Could not set fuel: {error}")),
                }
                store
            }) {
                submit_error(submit_reply, error);
            }
        }
        StoreTarget::Caller(session) => {
            if let Err(error) = session.submit(CallerCommand::SetFuel { fuel, reply }) {
                error.reject();
            }
        }
    }
    Ok(crate::atoms::ok())
}

#[rustler::nif(name = "store_or_caller_get_fuel")]
pub fn get_fuel(
    store_or_caller_resource: ResourceArc<StoreOrCallerResource>,
    from: Term,
) -> Result<Atom, rustler::Error> {
    let reply = AsyncReply::new(from)?;
    match store_or_caller_resource.target()? {
        StoreTarget::Executor(executor) => {
            let submit_reply = AsyncReply::new(from)?;
            if let Err(error) = executor.submit(move |store| async move {
                match store.get_fuel() {
                    Ok(fuel) => reply.send(fuel),
                    Err(error) => reply.send_error(format!("Could not get fuel: {error}")),
                }
                store
            }) {
                submit_error(submit_reply, error);
            }
        }
        StoreTarget::Caller(session) => {
            if let Err(error) = session.submit(CallerCommand::GetFuel { reply }) {
                error.reject();
            }
        }
    }
    Ok(crate::atoms::ok())
}

fn add_pipe<F>(
    pipe: Option<ExPipe>,
    builder: &mut WasiCtxBuilder,
    f: F,
) -> Result<(), rustler::Error>
where
    F: FnOnce(Pipe, &mut WasiCtxBuilder),
{
    if let Some(ExPipe { resource }) = pipe {
        let pipe = resource.pipe.lock().map_err(|_e| {
            rustler::Error::Term(Box::new(
                "Could not unlock resource as the mutex was poisoned.",
            ))
        })?;
        let pipe = pipe.clone();
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
    let guest_path = preopen.alias.as_ref().unwrap_or(path);
    builder
        .preopened_dir(path, guest_path, DirPerms::all(), FilePerms::all())
        .map_err(|err| Error::Term(Box::new(err.to_string())))?;
    Ok(())
}
