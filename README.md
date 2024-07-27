<p align="center">
  <img width="300" src="./logo.svg" alt="Wasmex logo">
</p>
<p align="center">
  <a href="https://github.com/tessi/wasmex/blob/master/LICENSE">
    <img src="https://img.shields.io/github/license/tessi/wasmex.svg" alt="License">
  </a>
  <a href="https://github.com/tessi/wasmex/actions/workflows/elixir-ci.yml">
    <img src="https://github.com/tessi/wasmex/actions/workflows/elixir-ci.yml/badge.svg?branch=main" alt="CI">
  </a>
</p>

Wasmex is a fast and secure [WebAssembly](https://webassembly.org/) and [WASI](https://github.com/WebAssembly/WASI) runtime for Elixir.
It enables lightweight WebAssembly containers to be run in your Elixir backend.

It uses [wasmtime](https://wasmtime.dev) to execute Wasm binaries through a [Rust](https://www.rust-lang.org) NIF.

Documentation can be found at [https://hexdocs.pm/wasmex](https://hexdocs.pm/wasmex/Wasmex.html).

## Install

The package can be installed by adding `wasmex` to your list of
dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:wasmex, "~> 0.9.1"}
  ]
end
```

## Example

There is a toy Wasm program in `test/wasm_test/src/lib.rs`, written in Rust (but could potentially be any other language that compiles to WebAssembly).
It defines many functions we use for end-to-end testing, but also serves as example code. For example:

```rust
#[no_mangle]
pub extern fn sum(x: i32, y: i32) -> i32 {
    x + y
}
```

Once this program compiled to WebAssembly (which we do every time when running tests), we end up with a `wasmex_test.wasm` binary file.

This Wasm file can be executed in Elixir:

```elixir
bytes = File.read!("wasmex_test.wasm")
{:ok, pid} = Wasmex.start_link(%{bytes: bytes}) # starts a GenServer running a Wasm instance
{:ok, [42]} == Wasmex.call_function(pid, "sum", [50, -8])
```

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

Using WebAssembly on an Elixir host is great not only, but especially for the following use cases:

* Running user-provided code safely
* Share business logic between systems written in different programming languages. E.g. a JS frontend and Elixir backend
* Run existing libraries/programs and easily interface them from Elixir

## Development

To set up a development environment install [the latest stable rust](https://www.rust-lang.org/tools/install) and rust-related tooling:

```bash
rustup component add rustfmt
rustup component add clippy
rustup target add wasm32-unknown-unknown # to compile our example Wasm files for testing
rustup target add wasm32-wasi # to compile our example Wasm/WASI files for testing
```

Then install the erlang/elixir dependencies:

```bash
asdf install # assuming you install elixir, erlang with asdf. if not, make sure to install them your way
mix deps.get
```

If you plan to change something on the Rust part of this project, set the following ENV `WASMEX_BUILD=true` so that your changes will be picked up.

I´m looking forward to your contributions. Please open a PR containing the motivation of your change. If it is a bigger change or refactoring, consider creating an issue first. We can discuss changes there first which might safe us time down the road :)

Any changes should be covered by tests, they can be run with `mix test`.
In addition to tests, we expect the formatters and linters (`cargo fmt`, `cargo clippy`, `mix format`, `mix credo`) to pass.

### Release

To release this package, make sure CI is green, increase the package version, and:

```
git tag -a v0.8.0 # change version accordingly, copy changelog into tag message
git push --tags
mix rustler_precompiled.download Wasmex.Native --all --ignore-unavailable --print
```

Inspect it's output carefully, but ignore NIF version `2.14` and `arm-unknown-linux-gnueabihf` arch errors because we don't build for them.
Now inspect the checksum-Elixir.Wasmex.Native.exs file - it should include all prebuilt binaries in their checksums

Then continue with

```
mix hex.publish
```

## License

The entire project is under the MIT License. Please read [the`LICENSE` file](https://github.com/tessi/wasmex/blob/master/LICENSE).

### Licensing

Unless you explicitly state otherwise, any contribution intentionally submitted
for inclusion in the work by you, shall be licensed as above, without any
additional terms or conditions.
