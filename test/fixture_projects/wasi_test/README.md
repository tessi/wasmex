# WASI Test

This sub-project generates a Wasm binary which relies on WASI calls.
It is used in our integration tests and built every time we run our tests.

## Manual Building

Firstly, make sure you are running the latest version of Rust stable, v1.36.0 or newer.
If not, go ahead and install it.

Next, install the required target

```
$ rustup target add wasm32-wasip1
```

Afterwards, you should be able to cross-compile to WASI by simply running

```
$ cargo build --target=wasm32-wasip1
```
