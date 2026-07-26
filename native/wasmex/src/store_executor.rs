use std::{
    future::Future,
    pin::Pin,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
};

use tokio::sync::mpsc;
use wasmtime::{Engine, Store, UpdateDeadline};

const DEFAULT_QUEUE_CAPACITY: usize = 1024;

type StoreFuture<T> = Pin<Box<dyn Future<Output = Store<T>> + Send + 'static>>;
type StoreCommand<T> = Box<dyn FnOnce(Store<T>) -> StoreFuture<T> + Send + 'static>;

pub trait InterruptState {
    fn interrupt_requested(&self) -> &AtomicBool;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SubmitError {
    Busy,
    Closed,
}

/// Serializes access to a Wasmtime Store without blocking an executor thread.
///
/// A Store is owned by one long-lived Tokio task. NIF calls enqueue owned
/// commands and return to the BEAM; the executor runs one command at a time,
/// preserving Wasmtime's single-owner requirement.
pub struct StoreExecutor<T: 'static> {
    sender: mpsc::Sender<StoreCommand<T>>,
    engine: Engine,
}

impl<T: 'static> Clone for StoreExecutor<T> {
    fn clone(&self) -> Self {
        Self {
            sender: self.sender.clone(),
            engine: self.engine.clone(),
        }
    }
}

impl<T: InterruptState + Send + 'static> StoreExecutor<T> {
    pub(crate) fn new_async(mut store: Store<T>, epoch_ticker: crate::engine::EpochTicker) -> Self {
        store.set_epoch_deadline(1);
        store.epoch_deadline_callback(|store| {
            if store.data().interrupt_requested().load(Ordering::Acquire) {
                Ok(UpdateDeadline::Interrupt)
            } else {
                Ok(UpdateDeadline::Yield(1))
            }
        });
        Self::with_capacity(store, DEFAULT_QUEUE_CAPACITY, Some(epoch_ticker))
    }
}

impl<T: Send + 'static> StoreExecutor<T> {
    fn with_capacity(
        store: Store<T>,
        capacity: usize,
        epoch_ticker: Option<crate::engine::EpochTicker>,
    ) -> Self {
        let engine = store.engine().clone();
        let (sender, mut receiver) = mpsc::channel::<StoreCommand<T>>(capacity);

        crate::engine::TOKIO_RUNTIME.spawn(async move {
            let _epoch_ticker = epoch_ticker;
            let mut store = store;
            while let Some(command) = receiver.recv().await {
                store = command(store).await;
            }
        });

        Self { sender, engine }
    }

    pub fn engine(&self) -> &Engine {
        &self.engine
    }

    pub fn submit<F, Fut>(&self, command: F) -> Result<(), SubmitError>
    where
        F: FnOnce(Store<T>) -> Fut + Send + 'static,
        Fut: Future<Output = Store<T>> + Send + 'static,
    {
        self.sender
            .try_send(Box::new(move |store| Box::pin(command(store))))
            .map_err(|error| match error {
                mpsc::error::TrySendError::Full(_) => SubmitError::Busy,
                mpsc::error::TrySendError::Closed(_) => SubmitError::Closed,
            })
    }
}

pub async fn with_deadline<F>(
    interrupt_requested: Arc<AtomicBool>,
    deadline: Option<tokio::time::Instant>,
    future: F,
) -> Option<F::Output>
where
    F: Future,
{
    let Some(deadline) = deadline else {
        return Some(future.await);
    };
    interrupt_requested.store(false, Ordering::Release);
    if deadline <= tokio::time::Instant::now() {
        return None;
    }

    tokio::pin!(future);
    tokio::select! {
        biased;
        _ = tokio::time::sleep_until(deadline) => {
            interrupt_requested.store(true, Ordering::Release);
            let _ = future.await;
            interrupt_requested.store(false, Ordering::Release);
            None
        }
        output = &mut future => Some(output),
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
    };

    use wasmtime::{Engine, Store};

    use super::{StoreExecutor, SubmitError};

    #[test]
    fn executes_commands_in_submission_order() {
        let executor =
            StoreExecutor::with_capacity(Store::new(&Engine::default(), 0usize), 2, None);
        let observed = Arc::new(AtomicUsize::new(0));

        for expected in 0..2 {
            let observed = observed.clone();
            executor
                .submit(move |mut store| async move {
                    assert_eq!(*store.data(), expected);
                    *store.data_mut() += 1;
                    observed.fetch_add(1, Ordering::SeqCst);
                    store
                })
                .unwrap();
        }

        while observed.load(Ordering::SeqCst) != 2 {
            std::thread::yield_now();
        }
    }

    #[test]
    fn reports_backpressure() {
        let executor = StoreExecutor::with_capacity(Store::new(&Engine::default(), ()), 1, None);
        let (started_tx, started_rx) = std::sync::mpsc::channel();
        let (finish_tx, finish_rx) = tokio::sync::oneshot::channel();
        let (finish_queued_tx, finish_queued_rx) = tokio::sync::oneshot::channel();

        executor
            .submit(move |store| async move {
                started_tx.send(()).unwrap();
                let _ = finish_rx.await;
                store
            })
            .unwrap();
        started_rx.recv().unwrap();

        executor
            .submit(move |store| async move {
                let _ = finish_queued_rx.await;
                store
            })
            .unwrap();

        assert_eq!(
            executor.submit(|store| async move { store }),
            Err(SubmitError::Busy)
        );
        finish_tx.send(()).unwrap();
        finish_queued_tx.send(()).unwrap();
    }
}
