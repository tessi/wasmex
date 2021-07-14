<p align="center">
  <img width="300" src="./logo.svg" alt="Wasmex logo">
</p>
<p align="center">
  <a href="https://github.com/tessi/wasmex/blob/master/LICENSE">
    <img src="https://img.shields.io/github/license/tessi/wasmex.svg" alt="License">
  </a>
  <a href="https://circleci.com/gh/tessi/wasmex">
    <img src="https://circleci.com/gh/tessi/wasmex.svg?style=svg" alt="CI">
  </a>
</p>

Wasmex is a fast and secure [WebAssembly](https://webassembly.org/) and [WASI](https://github.com/WebAssembly/WASI) runtime for Elixir.
It enables lightweight WebAssembly containers to be run in your Elixir backend.

It uses [wasmer](https://wasmer.io/) to execute WASM binaries through a NIF.
We use [Rust][https://www.rust-lang.org/] to implement the NIF to make it as safe as possible.

# Install

The package can be installed by adding `wasmex` to your list of
dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:wasmex, "~> 0.4.0"}
  ]
end
```

**Note**: [Rust][https://www.rust-lang.org/] is required to install the Elixir library (Cargo — the build tool for Rust — is used to compile the extension).
See [how to install Rust][https://www.rust-lang.org/tools/install].

The docs can be found at [https://hexdocs.pm/wasmex](https://hexdocs.pm/wasmex).

# Example

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
{:ok, instance } = Wasmex.start_link(%{bytes: bytes}) # starts a GenServer running this WASM instance

{:ok, [42]} == Wasmex.call_function(instance, "sum", [50, -8])
```

# Documentation

Please visit the [`Wasmex documentation`](https://hexdocs.pm/wasmex/Wasmex.html) for further info.
If a topic is not covered (in the needed depth) there, please open an issue.

# What is WebAssembly?

Quoting [the WebAssembly site][https://webassembly.org/]:

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

# License

The entire project is under the MIT License. Please read [the`LICENSE` file][https://github.com/tessi/wasmex/blob/master/LICENSE].
