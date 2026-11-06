use std::sync::{Arc, LazyLock, Weak};
use std::time::Duration;
use wasmtime::Engine;

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

// Wasm can occupy every Store worker until the next epoch. Advance epochs on a
// separate worker so Wasm can still yield and observe timeouts under load.
static EPOCH_RUNTIME: LazyLock<tokio::runtime::Runtime> = LazyLock::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(1)
        .thread_name("wasmex-epoch")
        .enable_time()
        .build()
        .expect("Failed to create epoch ticker runtime")
});

struct EpochTickerState {
    engine: Engine,
}

#[derive(Clone)]
pub(crate) struct EpochTicker {
    _state: Arc<EpochTickerState>,
}

impl EpochTicker {
    pub(crate) fn new(engine: Engine) -> Self {
        let state = Arc::new(EpochTickerState { engine });
        let weak_state: Weak<EpochTickerState> = Arc::downgrade(&state);

        EPOCH_RUNTIME.spawn(async move {
            let mut interval = tokio::time::interval(Duration::from_millis(10));
            interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

            loop {
                interval.tick().await;
                let Some(state) = weak_state.upgrade() else {
                    break;
                };
                state.engine.increment_epoch();
            }
        });

        Self { _state: state }
    }
}
