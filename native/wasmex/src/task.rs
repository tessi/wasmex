use once_cell::sync::Lazy;
use rustler::{Atom, Encoder, Env, NifResult, OwnedEnv};
use std::future::{Future, IntoFuture};
use tokio::runtime::{Builder, Runtime};
use tokio::task::{self, JoinHandle};
use futures_lite::future;

use crate::atoms;

// TODO: build the runtime on the NIFs init fn
static TOKIO: Lazy<Runtime> = Lazy::new(|| {
    Builder::new_multi_thread()
        .enable_time()
        .enable_io()
        .build()
        .expect("Wasmex.Native: Failed to start tokio runtime")
});

pub fn spawn<T>(task: T) -> JoinHandle<T::Output>
where
    T: Future + Send + 'static,
    T::Output: Send + 'static,
{
    TOKIO.spawn(task)
}

pub fn send_async_nif_result<T, E, Fut>(env: Env, future: Fut) -> NifResult<(Atom, Atom)>
where
    T: Encoder,
    E: Encoder,
    Fut: future::Future<Output = Result<T, E>> + Send + 'static,
{
    let pid = env.pid();
    let mut my_env = OwnedEnv::new();
    let result_key = atoms::async_nif_result();
    task::spawn(async move {
        let result = future.await;
        match result {
            Ok(worker) => {
                let _ = my_env
                    .send_and_clear(&pid, |env| (result_key, (atoms::ok(), worker)).encode(env));
            }
            Err(err) => {
                let _ = my_env
                    .send_and_clear(&pid, |env| (result_key, (atoms::error(), err)).encode(env));
            }
        }
    }).into_future();

    Ok((atoms::ok(), result_key))
}
