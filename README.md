<p align="center">
  <img width="300" src="./logo.svg" alt="Wasmex logo">
</p>
<p align="center">
  <a href="https://github.com/tessi/wasmex/blob/master/LICENSE">
    <img src="https://img.shields.io/github/license/tessi/wasmex.svg" alt="License">
  </a>
  <a href="https://github.com/tessi/wasmex/actions/workflows/elixir-ci.yaml">
    <img src="https://github.com/tessi/wasmex/actions/workflows/elixir-ci.yaml/badge.svg?branch=main" alt="CI">
  </a>
</p>

Wasmex is a fast and secure [WebAssembly](https://webassembly.org/) and [WASI](https://github.com/WebAssembly/WASI) runtime for Elixir.
It enables lightweight WebAssembly containers to be run in your Elixir backend.

It uses [wasmer](https://wasmer.io/) to execute WASM binaries through a NIF.
We use [Rust](https://www.rust-lang.org/) to implement the NIF to make it as safe as possible.

## Install

The package can be installed by adding `wasmex` to your list of
dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:wasmex, "~> 0.7.1"}
  ]
end
```

The docs can be found at [https://hexdocs.pm/wasmex](https://hexdocs.pm/wasmex/Wasmex.html).

## Example

There is a toy WASM program in `test/wasm_test/src/lib.rs`, written in Rust (but could potentially be any other language that compiles to WebAssembly).
It defines many functions we use for end-to-end testing, but also serves as example code. For example:

```rust
#[no_mangle]
pub extern fn sum(x: i32, y: i32) -> i32 {
    x + y
}
```

Once this program compiled to WebAssembly (which we do every time when running tests), we end up with a `wasmex_test.wasm` binary file.

This WASM file can be executed in Elixir:

```elixir
{:ok, bytes } = File.read("wasmex_test.wasm")
{:ok, module} = Wasmex.Module.compile(bytes)
{:ok, instance } = Wasmex.start_link(%{module: module}) # starts a GenServer running this WASM instance

{:ok, [42]} == Wasmex.call_function(instance, "sum", [50, -8])
```

## Documentation

Please visit the [`Wasmex documentation`](https://hexdocs.pm/wasmex/Wasmex.html) for further info.
If a topic is not covered (in the needed depth) there, please open an issue.

## What is WebAssembly?

Quoting [the WebAssembly site](https://webassembly.org/):

> WebAssembly (abbreviated Wasm) is a binary instruction format for a
> stack-based virtual machine. Wasm is designed as a portable target
> for compilation of high-level languages like C/C++/Rust, enabling
> deployment on the web for client and server applications.

About speed:

> WebAssembly aims to execute at native speed by taking advantage of
> [common hardware
> capabilities](https://webassembly.org/docs/portability/#assumptions-for-efficient-execution)
> available on a wide range of platforms.

About safety:

> WebAssembly describes a memory-safe, sandboxed [execution
> environment](https://webassembly.org/docs/semantics/#linear-memory) […].

## Development

To set up a development environment install [the latest stable rust](https://www.rust-lang.org/tools/install) and rust-related tooling:

```bash
rustup component add rustfmt
rustup component add clippy
rustup target add wasm32-unknown-unknown # to compile our example WASM files for testing
rustup target add wasm32-wasi # to compile our example WASM/WASI files for testing
```

Then install the erlang/elixir dependencies:

```bash
asdf install # assuming you install elixir, erlang with asdf. if not, make sure to install them your way
mix deps.get
```

If you plan to change something on the Rust part of this project, set the following ENV `WASMEX_BUILD=true` so that your changes will be picked up.

I´m looking forward to your contributions. Please open a PR containing the motivation of your change. If it is a bigger change or refactoring, consider creating an issue first. We can discuss changes there first which might safe us time down the road :)

Any changes should be covered by tests, they can be run with `mix test`.
In addition to tests, we expect the formatters and linters (`cargo fmt`, `cargo clippy`, `mix format`, `mix dialyzer`, `mix credo`) to pass.

Your contributions will be licenced under the same license as this project.

## License

The entire project is under the MIT License. Please read [the`LICENSE` file](https://github.com/tessi/wasmex/blob/master/LICENSE).
