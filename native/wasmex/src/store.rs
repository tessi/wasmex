use rustler::{resource::ResourceArc, Error, NifResult};
use std::{collections::HashMap, sync::Mutex};
use wasi_common::WasiCtx;
use wasmtime::{Config, Engine, Store};
use wasmtime_wasi::WasiCtxBuilder;

use crate::{
    atoms,
    environment::{StoreOrCaller, StoreOrCallerResource, StoreOrCallerResourceResponse},
    pipe::{Pipe, PipeResource},
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
#[rustler(decode)]
pub struct ExWasiOptions {
    pub(crate) args: Vec<String>,
    pub(crate) env: HashMap<String, String>,
    pub(crate) stderr: Option<ExPipe>,
    pub(crate) stdin: Option<ExPipe>,
    pub(crate) stdout: Option<ExPipe>,
    pub(crate) preopen: Vec<ExWasiPreopenOptions>,
}

pub struct StoreData {
    pub(crate) wasi: Option<WasiCtx>,
}

#[rustler::nif(name = "store_new")]
pub fn new() -> NifResult<StoreOrCallerResourceResponse> {
    let config = Config::new();
    let engine = Engine::new(&config).map_err(|err| Error::Term(Box::new(err.to_string())))?;
    let store = Store::new(&engine, StoreData { wasi: None });
    let resource = ResourceArc::new(StoreOrCallerResource {
        inner: Mutex::new(StoreOrCaller::Store(store)),
    });
    Ok(StoreOrCallerResourceResponse {
        ok: atoms::ok(),
        resource,
    })
}

#[rustler::nif(name = "store_new_wasi")]
pub fn new_wasi(options: ExWasiOptions) -> NifResult<StoreOrCallerResourceResponse> {
    let wasi_env = &options
        .env
        .iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect::<Vec<_>>();

    let builder = WasiCtxBuilder::new()
        .args(&options.args)
        .map_err(|err| Error::Term(Box::new(err.to_string())))?
        .envs(wasi_env)
        .map_err(|err| Error::Term(Box::new(err.to_string())))?;

    let builder = add_pipe(options.stdin, builder, |pipe, builder| builder.stdin(pipe))?;
    let builder = add_pipe(options.stdout, builder, |pipe, builder| {
        builder.stdout(pipe)
    })?;
    let builder = add_pipe(options.stderr, builder, |pipe, builder| {
        builder.stderr(pipe)
    })?;
    let builder = wasi_preopen_directories(options.preopen, builder)?;
    let wasi_ctx = builder.build();

    let config = Config::new();
    let engine = Engine::new(&config).map_err(|err| Error::Term(Box::new(err.to_string())))?;
    let store = Store::new(
        &engine,
        StoreData {
            wasi: Some(wasi_ctx),
        },
    );
    let resource = ResourceArc::new(StoreOrCallerResource {
        inner: Mutex::new(StoreOrCaller::Store(store)),
    });
    Ok(StoreOrCallerResourceResponse {
        ok: atoms::ok(),
        resource,
    })
}

fn add_pipe(
    pipe: Option<ExPipe>,
    builder: WasiCtxBuilder,
    f: fn(Box<Pipe>, WasiCtxBuilder) -> WasiCtxBuilder,
) -> Result<WasiCtxBuilder, rustler::Error> {
    if let Some(ExPipe { resource }) = pipe {
        let pipe = resource.pipe.lock().map_err(|_e| {
            rustler::Error::Term(Box::new(
                "Could not unlock resource as the mutex was poisoned.",
            ))
        })?;
        let pipe = Box::new(pipe.clone());
        return Ok(f(pipe, builder));
    }
    Ok(builder)
}

fn wasi_preopen_directories(
    preopens: Vec<ExWasiPreopenOptions>,
    builder: WasiCtxBuilder,
) -> Result<WasiCtxBuilder, rustler::Error> {
    let builder = preopens.iter().fold(Ok(builder), |builder, preopen| {
        preopen_directory(builder, preopen)
    })?;
    Ok(builder)
}

fn preopen_directory(
    builder: Result<WasiCtxBuilder, Error>,
    preopen: &ExWasiPreopenOptions,
) -> Result<WasiCtxBuilder, Error> {
    let builder = builder?;
    let path = &preopen.path;
    let dir = wasmtime_wasi::Dir::from_std_file(
        std::fs::File::open(path).map_err(|err| rustler::Error::Term(Box::new(err.to_string())))?,
    );
    let guest_path = preopen.alias.as_ref().unwrap_or(path);
    let builder = builder
        .preopened_dir(dir, guest_path)
        .map_err(|err| Error::Term(Box::new(err.to_string())))?;
    Ok(builder)
}
