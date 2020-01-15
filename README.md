<p align="center">
  <a href="https://wasmer.io" target="_blank" rel="noopener">
    <img width="300" src="https://raw.githubusercontent.com/wasmerio/wasmer/master/logo.png" alt="Wasmer logo">
  </a>
</p>

<p align="center">
  <a href="https://github.com/tessi/wasmex/blob/master/LICENSE">
    <img src="https://img.shields.io/github/license/wasmerio/wasmer.svg" alt="License">
  </a>
  [![CircleCI](https://circleci.com/gh/tessi/wasmex.svg?style=svg)](https://circleci.com/gh/tessi/wasmex)
</p>

Wasmex is an Elixir library for executing WebAssembly binaries:

 * **Easy to use**: The `wasmex` API mimics the standard WebAssembly API,
 * **Fast**: `wasmex` executes the WebAssembly modules as fast as possible,
 * **Safe**: All calls to WebAssembly will be fast and completely safe and sandboxed.

# Install

The package can be installed by adding `wasmex` to your list of
dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:wasmex, "~> 0.1.0"}
  ]
end
```

**Note**: [Rust][rust] is required to install the Elixir library (Cargo — the build tool for Rust — is used to compile the extension). See [how to install Rust][install-rust].

[rust]: https://www.rust-lang.org/
[install-rust]: https://www.rust-lang.org/tools/install

The docs can be found at [https://hexdocs.pm/wasmex](https://hexdocs.pm/wasmex).

# Example

There is a toy WASM program in `test/wasm_source/src/lib.rs`, written in Rust (but could potentially be any other language that compiles to Wasm).
It defines many functions we use for end-to-end testing, but also serves as example code. For example:

```rust
#[no_mangle]
pub extern fn sum(x: i32, y: i32) -> i32 {
    x + y
}
```

Once this program compiled to WebAssembly (which we do every time when running tests), we end up with a `test/wasm_source/target/wasm32-unknown-unknown/debug/wasmex_test.wasm` binary file.

This WASM file can be executed in Elixir:

```elixir
{:ok, bytes } = File.read("wasmex_test.wasm")
{:ok, instance } = Wasmex.Instance.from_bytes(bytes)

instance
  |> Wasmex.Instance.call_exported_function("sum", [50, -8])
```

# API Overview

## The `Instance` module

Instantiates a WebAssembly module represented by bytes and allows calling exported functions on it:

```elixir
# Get the Wasm module as bytes.
{:ok, bytes } = File.read("wasmex_test.wasm")

# Instantiates the Wasm module.
{:ok, instance } = Wasmex.Instance.from_bytes(bytes)

# Call a function on it.
result = Wasmex.Instance.call_exported_function(instance, "sum", [1, 2])

IO.puts result # 3
```

All exported functions are accessible via the `call_exported_function` function. Arguments of these functions are automatically casted to WebAssembly values.
Note that WebAssembly only knows number datatypes (floats and integers of various sizes).

You can pass arbitrary data to WebAssembly, though, by writing this data into its memory. The `memory` function returns a `Memory` struct representing the memory of that particular instance, e.g.:

```elixir
{:ok, memory} = Wasmex.Instance.memory(instance, :uint8, 0)
```

See below for more information.

## The `Memory` module

A WebAssembly instance has its own memory, represented by the `Memory` struct.
It is accessible by the `Wasmex.Instance.memory` getter.

The `Memory.grow` methods allows to grow the memory by a number of pages (of 65kb each).

```elixir
Wasmex.Memory.grow(memory, 1)
```

The current size of the memory can be obtained with the `length` method:

```elixir
Wasmex.Memory.length(memory) # in bytes, always a multiple of the the page size (65kb)
```

When creating the memory struct, the `offset` param can be provided, to subset the memory array at a particular offset.

```elixir
offset = 7
index = 4
value = 42

{:ok, memory} = Wasmex.Instance.memory(instance, :uint8, offset)
Wasmex.Memory.set(memory, index, value)
IO.puts Wasmex.Memory.get(memory, index) # 42
```

### Memory Buffer viewed in different Datatypes

The `Memory` struct views the WebAssembly memory of an instance as an array of values of different types.
Possible types are: `uint8`, `int8`, `uint16`, `int16`, `uint32`, and `int32`.
The underlying data is not changed when viewed in different types - its just its representation that changes.

| View memory buffer as a sequence of… | Bytes per element |
|----------|---|
| `int8`   | 1 |
| `uint8`  | 1 |
| `int16`  | 2 |
| `uint16` | 2 |
| `int32`  | 4 |
| `uint32` | 4 |

This can also be resolved at runtime:

```elixir
{:ok, memory} = Wasmex.Instance.memory(instance, :uint16, 0)
Wasmex.Memory.bytes_per_element(memory) # 2
```

Since the same memory seen in different data types uses the same buffer internally. Let's have some fun:

```elixir
int8 = Wasmex.Instance.memory(instance, :int8, 0)
int16 = Wasmex.Instance.memory(instance, :int16, 0)
int32 = Wasmex.Instance.memory(instance, :int32, 0)

                        b₁
                     ┌┬┬┬┬┬┬┐
Memory.set(int8, 0, 0b00000001)
                        b₂
                     ┌┬┬┬┬┬┬┐
Memory.set(int8, 1, 0b00000100)
                        b₃
                     ┌┬┬┬┬┬┬┐
Memory.set(int8, 2, 0b00010000)
                        b₄
                     ┌┬┬┬┬┬┬┐
Memory.set(int8, 3, 0b01000000)

# Viewed in `int16`, 2 bytes are read per value
            b₂       b₁
         ┌┬┬┬┬┬┬┐ ┌┬┬┬┬┬┬┐
assert 0b00000100_00000001 == Memory.get(int16, 0)
            b₄       b₃
         ┌┬┬┬┬┬┬┐ ┌┬┬┬┬┬┬┐
assert 0b01000000_00010000 == Memory.get(int16, 1)

# Viewed in `int32`, 4 bytes are read per value
            b₄       b₃       b₂       b₁
         ┌┬┬┬┬┬┬┐ ┌┬┬┬┬┬┬┐ ┌┬┬┬┬┬┬┐ ┌┬┬┬┬┬┬┐
assert 0b01000000_00010000_00000100_00000001 == Memory.get(int32, 0)
```

### Strings as Parameters and Return Values

Strings can not directly be used as parameters or return values when calling WebAssembly functions since WebAssembly only knows number data types.
But since Strings are just "a bunch of bytes" we can write these bytes into memory and give our WebAssembly function a pointer to that memory location.

#### Strings as Function Parameters

Given we have the following Rust function in our WebAssembly (copied from our test code):

```rust
#[no_mangle]
pub extern "C" fn string_first_byte(s: &str) -> u8 {
  match s.bytes().nth(0) {
    Some(i) => i,
    None => 0
  }
}
```

This function returns the first byte of the given String.
Let's see how we can call this function from Elixir:

```elixir
bytes = File.read!(TestHelper.wasm_file_path)
{:ok, instance} = Wasmex.Instance.from_bytes(bytes)
{:ok, memory} = Wasmex.Instance.memory(instance, :uint8, 0)
index = 42
string = "hello, world"

Wasmex.Memory.write_binary(memory, index, string)
Wasmex.Instance.call_exported_function(instance, "string_first_byte", [index, String.length(string)]) # 104, "h" in ASCII/UTF-8
```

Please not that Elixir and Rust assume Strings to be valid UTF-8. Take care when handling other encodings.

#### Strings as Function Return Values

Given we have the following Rust function in our WebAssembly (copied from our test code):

```rust
#[no_mangle]
pub extern "C" fn string() -> *const u8 {
    b"Hello, World!\0".as_ptr()
}
```

This function returns a pointer to its memory.
This memory location contains the String "Hello, World!" (ending with a null-byte since in C-land all strings end with a null-byte to mark the end of the string).

This is how we would receive this String in Elixir:

```elixir
bytes = File.read!(TestHelper.wasm_file_path)
{:ok, instance} = Wasmex.Instance.from_bytes(bytes)
{:ok, memory} = Wasmex.Instance.memory(instance, :uint8, 0)

pointer = Wasmex.Instance.call_exported_function(instance, "string", [])
returned_string = Wasmex.Memory.read_binary(memory, pointer) # "Hellow, World!"
```

# Endianness of WASM Values

Please note that bytes are treated in little-endian, as required by the
WebAssembly specification, [Chapter Structure, Section Instructions,
Sub-Section Memory
Instructions](https://webassembly.github.io/spec/core/syntax/instructions.html#memory-instructions):

> All values are read and written in [little
> endian](https://en.wikipedia.org/wiki/Endianness#Little-endian) byte
> order.

# What is WebAssembly?

Quoting [the WebAssembly site][wasm]:

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

[wasm]: https://webassembly.org/

# License

The entire project is under the MIT License. Please read [the
`LICENSE` file][license].

[license]: https://github.com/tessi/wasmex/blob/master/LICENSE

Many parts of this project are heavily inspired by the [wasmerio family of language integrations](https://github.com/wasmerio). These are also MIT licensed.
