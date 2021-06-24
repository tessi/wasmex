# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Types of changes

- `Added` for new features.
- `Changed` for changes in existing functionality.
- `Deprecated` for soon-to-be removed features.
- `Removed` for now removed features.
- `Fixed` for any bug fixes.
- `Security` in case of vulnerabilities.

## [unreleased changes]

- put new changes here

## [0.4.0] - 2021-06-24

### Added

- added support for OTP 24.0 (by updating rustler)

### Changed

- Wasmex.Memory.bytes_per_element changed its signature from
  `Wasmex.Memory.bytes_per_element(memory, :uint32, 0)` to `Wasmex.Memory.bytes_per_element(:uint32)`.
  The existing signature `Wasmex.Memory.bytes_per_element(memory)` still works as before.

#### Removed

- `Wasmex.Memory.grow/4` was removed. Instead `Wasmex.Memory.grow/2` can be used interchangeably.

## [0.3.1] - 2021-04-04

### Added

- added support for `aarch64-darwin` (apple silicon). Thanks @epellis

### Changed

- removed use of `unsafe` from wasm<->elixir value conversion. Thanks @Virviil

## [0.3.0] - 2021-01-09

## Notable Changes

This release features support for elixir function that can be exported to WASM.

It also supports [the latest wasmer v 1.0](https://medium.com/wasmer/wasmer-1-0-3f86ca18c043) 🎉.
Wasmer 1.0 is a partial rewrite of the WASM engine we use that promises to be up to 9 times faster module compilation.

### Added

- added the instances first memory into the callback context

```elixir
imports = %{
  env: %{
    read_and_set_memory:
      {:fn, [], [:i32],
        fn context, a, b, c ->
          memory = Map.get(context, :memory)
          42 = Wasmex.Memory.get(memory, :uint8, 0, 0) # assert that the first byte in the memory was set to 42
          Wasmex.Memory.set(memory, :uint8, 0, 0, 23)
          0
        end},
  }
}

instance = start_supervised!({Wasmex, %{bytes: @import_test_bytes, imports: imports}})
Wasmex.Memory.set(memory, :uint8, 0, 0, 42)

# asserts that the byte at memory[0] was set to 42 and then sets it to 23
{:ok, _} = Wasmex.call_function(instance, :a_wasm_fn_that_calls_read_and_set_memory, [])

assert 23 == Wasmex.Memory.get(memory, :uint8, 0, 0)
```

- added support for function imports

```elixir
imports = %{
  env: %{
    sum3: {:fn, [:i32, :i32, :i32], [:i32], fn (_context, a, b, c) -> a + b + c end},
  }
}
instance = start_supervised!({Wasmex, %{bytes: @import_test_bytes, imports: imports}})

{:ok, [6]} = Wasmex.call_function(instance, "use_the_imported_sum_fn", [1, 2, 3])
```

Thanks to

- @bamorim for helping me plan and architect,
- @myobie for help in implementation, especially for implementing the function signature checks,
- @rylev for a second eye on our Rust code,
- the @wasmerio team for the recent addition of `DynFunc` which made this feature possible, and
- @bitcrowd for sponsoring me to work on this feature

### Changed

- Changed writing and reading strings from/to memory to be based on string length and not expect null-byte terminated strings.
  This allows for a more flexible memory handling when writing arbitrary data or strings containing null bytes to/from memory.
  Thanks @myobie for implementing this feature
- Support writing non-string binaries to memory. Before we could only write valid UTF-8 strings to WASM memory.
  Thanks again, @myobie, for implementing this feature
- Updated the wasmer version, now supporting wasmer 1.0.
- Updated to elixir 1.11 and Erlang OTP 23.2. Older versions might work, but are not officially tested

### Fixed

- `could not convert callback result param to expected return signature` error for a void callback.

## [0.2.0] - 2020-04-14

This release brings is closer to a production-ready experience.
Calls of WebAssembly functions are now handled asynchronously: Invoking a WASM function via `Instance.call_exported_function` calls our Rust NIF as before, but does not directly execute the function. Instead, a new OS thread is spawned for the actual execution. This allows us to spend only few time in the NIF code (as required by the Erlang VM). Once the WASM function in that thread returns, we send a message to the calling erlang process.
To ease handling, we converted our main module `Wasmex` into a `GenServer` so that a WASM function call can be used in a synchronous manner as before.

### Added

- The `Wasmex` module is now a GenServer. WASM function calls are now asynchronous.

### Changed

- Removed unused Rust dependencies
- Provide better error messages for `Wasmex.Instance.from_bytes` when the WASM instance could not be instantiated.
- WASM function calls now return a list of return values instead of just one value (this is to prepare for WASM tu officially support multiple return values)
- Updated elixir and rust dependencies including wasmer to version 0.16.2

### Removed

- `Instance.call_exported_function/2` use `Instance.call_exported_function/3` instead.

### Fixed

- Enhanced documentation

## [0.1.0] - 2020-01-15

### Changed

- First release
