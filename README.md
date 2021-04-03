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

Wasmex is an Elixir library for executing WebAssembly binaries:

- **Easy to use**: The `wasmex` API mimics the standard WebAssembly API,
- **Fast**: `wasmex` executes the WebAssembly modules as fast as possible,
- **Safe**: All calls to WebAssembly will be fast and completely safe and sandboxed.

It uses [wasmer](https://wasmer.io/) to execute WASM binaries through a NIF. We use [Rust][rust] to implement the NIF to make it as safe as possible.

# Install

The package can be installed by adding `wasmex` to your list of
dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:wasmex, "~> 0.3.1"}
  ]
end
```

**Note**: [Rust][rust] is required to install the Elixir library (Cargo — the build tool for Rust — is used to compile the extension). See [how to install Rust][install-rust].

[rust]: https://www.rust-lang.org/
[install-rust]: https://www.rust-lang.org/tools/install

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

Once this program compiled to WebAssembly (which we do every time when running tests), we end up with a `test/wasm_test/target/wasm32-unknown-unknown/debug/wasmex_test.wasm` binary file.

This WASM file can be executed in Elixir:

```elixir
{:ok, bytes } = File.read("wasmex_test.wasm")
{:ok, instance } = Wasmex.start_link(bytes)

{:ok, [42]} == Wasmex.call_function(instance, "sum", [50, -8])
```

# API Overview

## The `Instance` module

Instantiates a WebAssembly module represented by bytes and allows calling exported functions on it:

```elixir
# Get the WASM module as bytes.
{:ok, bytes } = File.read("wasmex_test.wasm")

# Instantiates the WASM module.
{:ok, instance } = Wasmex.start_link(bytes)

# Call a function on it.
{:ok, [result]} = Wasmex.call_function(instance, "sum", [1, 2])

IO.puts result # 3
```

All exported functions are callable via `Wasmex.call_function`.
Arguments of these functions are automatically casted to WebAssembly values.
Note that WebAssembly only knows number datatypes (floats and integers of various sizes).

You can pass arbitrary data to WebAssembly, though, by writing this data into its memory. `Wasmex.memory` returns a `Memory` struct representing the memory of that particular instance, e.g.:

```elixir
{:ok, memory} = Wasmex.memory(instance, :uint8, 0)
```

See below for more information.

## Imports

Wasmex currently supports importing functions only.
We wish to support globals and tables in the future and appreciate any contributions in that direction.

To pass a function into a WASM module, an `imports map` must be provided:

```elixir
imports = %{
  env: %{
    sum3: {:fn, [:i32, :i32, :i32], [:i32], fn (_context, a, b, c) -> a + b + c end},
  }
}
instance = start_supervised!({Wasmex, %{bytes: @import_test_bytes, imports: imports}})

{:ok, [6]} = Wasmex.call_function(instance, "use_the_imported_sum_fn", [1, 2, 3])
```

The imports object is a map of namespaces.
In the example above, we import the `"env"` namespace.
Each namespace is, again, a map listing imports.
Under the name `sum3`, we imported a function which is represented with a tuple of:

1. the import type: `:fn` (a function),
1. the functions parameter types: `[:i32, :i32, :i32]`,
1. the functions return types: `[:i32]`, and
1. a function reference: `fn (_context, a, b, c) -> a + b + c end`

When the WASM code executes the `sum3` imported function, the execution context is forwarded to
the given function reference.
The first param is always the call context (containing e.g. the instances memory).
All other params are regular parameters as specified by the parameter type list.

Valid parameter/return types are:

- `i32` a 32 bit integer
- `i64` a 64 bit integer
- `f32` a 32 bit float
- `f64` a 64 bit float

## The `Memory` module

A WebAssembly instance has its own memory, represented by the `Memory` struct.
It is accessible by the `Wasmex.memory` getter.

The `Memory.grow` methods allows to grow the memory by a number of pages (of 65kb each).

```elixir
Wasmex.Memory.grow(memory, 1)
```

The current size of the memory can be obtained with the `length` method:

```elixir
Wasmex.Memory.length(memory) # in bytes, always a multiple of the the page size (65kb)
```

When creating the memory struct, an `offset` param can be provided to subset the memory array at a particular offset.

```elixir
offset = 7
index = 4
value = 42

{:ok, memory} = Wasmex.memory(instance, :uint8, offset)
Wasmex.Memory.set(memory, index, value)
IO.puts Wasmex.Memory.get(memory, index) # 42
```

### Memory Buffer viewed in different Datatypes

The `Memory` struct views the WebAssembly memory of an instance as an array of values of different types.
Possible types are: `uint8`, `int8`, `uint16`, `int16`, `uint32`, and `int32`.
The underlying data is not changed when viewed in different types - its just its representation that changes.

| View memory buffer as a sequence of… | Bytes per element |
| ------------------------------------ | ----------------- |
| `int8`                               | 1                 |
| `uint8`                              | 1                 |
| `int16`                              | 2                 |
| `uint16`                             | 2                 |
| `int32`                              | 4                 |
| `uint32`                             | 4                 |

This can also be resolved at runtime:

```elixir
{:ok, memory} = Wasmex.memory(instance, :uint16, 0)
Wasmex.Memory.bytes_per_element(memory) # 2
```

Since the same memory seen in different data types uses the same buffer internally. Let's have some fun:

```elixir
int8 = Wasmex.memory(instance, :int8, 0)
int16 = Wasmex.memory(instance, :int16, 0)
int32 = Wasmex.memory(instance, :int32, 0)

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

Given we have the following Rust function that returns the first byte of a given string
in our WebAssembly (note: this is copied from our test code, have a look there if you're interested):

```rust
#[no_mangle]
pub extern "C" fn string_first_byte(bytes: *const u8, length: usize) -> u8 {
    let slice = unsafe { slice::from_raw_parts(bytes, length) };
    match slice.first() {
        Some(&i) => i,
        None => 0,
    }
}
```

Let's see how we can call this function from Elixir:

```elixir
bytes = File.read!(TestHelper.wasm_test_file_path)
{:ok, instance} = Wasmex.start_link(bytes)
{:ok, memory} = Wasmex.memory(instance, :uint8, 0)
index = 42
string = "hello, world"
Wasmex.Memory.write_binary(memory, index, string)

# 104 is the letter "h" in ASCII/UTF-8 encoding
{:ok, [104]} == Wasmex.call_function(instance, "string_first_byte", [index, String.length(string)])
```

Please not that Elixir and Rust assume Strings to be valid UTF-8. Take care when handling other encodings.

#### Strings as Function Return Values

Given we have the following Rust function in our WebAssembly (copied from our test code):

```rust
#[no_mangle]
pub extern "C" fn string() -> *const u8 {
    b"Hello, World!".as_ptr()
}
```

This function returns a pointer to its memory.
This memory location contains the String "Hello, World!" (ending with a null-byte since in C-land all strings end with a null-byte to mark the end of the string).

This is how we would receive this String in Elixir:

```elixir
bytes = File.read!(TestHelper.wasm_test_file_path)
{:ok, instance} = Wasmex.start_link(bytes)
{:ok, memory} = Wasmex.memory(instance, :uint8, 0)

{:ok, [pointer]} = Wasmex.call_function(instance, "string", [])
returned_string = Wasmex.Memory.read_string(memory, pointer, 13) # "Hello, World!"
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
