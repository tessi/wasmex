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

## unreleased

put your changes here

## [0.8.4] - 2023-06-??

### Added

* added support for multi-value returns from WASM and elixir callbacks. This enables passing string return values safely by pointer and length, for example.

## [0.8.3] - 2023-05-24

### Added

* added support for `riscv64gc-unknown-linux-gnu`
* added support for OTP 26

### Changed

* updated rustler from 0.27.0 to 0.28.0
* updated wasmtime from 4.0.1 to 9.0.1

## [0.8.2] - 2023-01-08

## Added

* list `aarch64-unknown-linux-musl` in rustler targets, so we actually include it in our releases

## [0.8.1] - 2023-01-08

This release makes running user-provided Wasm binaries a whole bunch safter by providing restrictions on memory and CPU usage.

Have a look at `Wasmex.StoreLimits` for memory restrictions and `Wasmer.EngineConfig` on how to limit fuel (CPU usage quota).

The new `Wasmex.EngineConfig` allows better reporting when Wasm execution fails -- setting `wasm_backtrace_details` enables error backtraces to include file and line number information if that debug info is available in the running Wasm file.

A `Wasmex.EngineConfig` is used to create a `Wasmex.Engine`, which holds configuration for a `Wasmex.Store`. It allows us to selectively enable/disable more Wasm option (e.g. enabling certain Wasm proposals).
Today, a `Wasmex.Engine` already gives us a faster way to precompile modules without the need to instantiate them through `Wasmex.Engine.precompile_module/2`.

### Added

* Added precompiled binary for `aarch64-unknown-linux-musl`
* Added support for setting store limits. This allows users to limit memory usage, instance creation, table sizes and more. See `Wasmex.StoreLimits` for details.
* Added support for metering/fuel_consumption. This allows users to limit CPU usage. A `Wasmex.Store` can be given fuel, where each Wasm instruction  of a running Wasm binary uses a certain amount of fuel. If no fuel remains, execution stops. See `Wasmex.EngineConfig` for details.
* Added `Wasmex.EngineConfig` as a place for more complex Wasm settings. With this release an engine can be configured to provide more detailed backtraces on errors during Wasm execution by setting the `wasm_backtrace_details` flag.
* Added `Wasmex.Engine.precompile_module/2` which allows module precompilation from a .wat or .wasm binary without the need to instantiate said module. A precompiled module can be hydrated with `Module.unsafe_deserialize/2`.
* Added `Wasmex.module/1` and `Wasmex.store/1` to access the module and store of a running Wasmex GenServer process.
* Added option to `Wasmex.EngineConfig` to configure the `cranelift_opt_level` (:none, :speed, :speed_and_size) allowing users to trade compilation time against execution speed

### Changed

* `mix.exs` now also requires at least Elixir 1.12
* `Module.unsafe_deserialize/2` now accepts a `Wasmex.Engine` in addition to the serialized module binary. It's best to hydrate a module using the same engine config used to serialize or precompile it. It has no harsh consequences today, but will be important when we add more Wasm features (e.g. SIMD support) in the future.
* added typespecs for all public `Wasmex` methods
* improved documentation and typespecs
* allow starting the `Wasmex` GenServer with a `%{bytes: bytes, store: store}` map as a convenience to spare users the task of manually compiling a `Wasmex.Module`


## [0.8.0] - 2023-01-03

This release brings some changes to our API because of the change of the underlying Wasm engine to [wasmtime](https://wasmtime.dev/).

It brings a new abstraction, the `Wasmex.Store`, which holds all internal structures. Thus, the store (or a "caller" in function-call contexts) needs
to be provided in most Wasmex APIs in the form of a `Wasmex.StoreOrCaller` struct.

The Wasm engine change requires us to do further changes, most notably
a change in how `Wasmex.Memory` is accessed. We dropped support for
different data types and simplified the memory model to be just an array of bytes.
The concept of memory offsets was dropped.

Please visit the list of changes below for more details.

### Added

* Added support for OTP 25
* Added support for Elixir 1.14

### Removed

* Removed official support for OTP 22 and 23
* Removed official support for Elixir 1.12
* Removed `Wasmex.Module.set_name()` without replacement as this is not supported by Wasmtime
* Removed `Wasmex.Memory.bytes_per_element()` without replacement because we dropped support for different data types and now only handle bytes
* Removed `Wasmex.Pipe.set_len()` without replacement
* WASI directory/file preopens can not configure read/write/create permissions anymore because wasmtime does not support this feature well. We very much plan to add support back [once wasmtime allows](https://github.com/bytecodealliance/wasmtime/issues/4273).

### Changed

* Changed the underlying Wasm engine from wasmer to [wasmtime](https://wasmtime.dev)
* Removed `Wasmex.Instance.new()` and `Wasmex.Instance.new_wasi()` in favor of `Wasmex.Store.new()` and `Wasmex.Store.new_wasi()`.
* WASI-options to `Wasmex.Store.new_wasi()` are now a proper struct `Wasmex.Wasi.WasiOptions` to improve typespecs, docs, and compile-time warnings.
* `Wasmex.Pipe` went through an internal rewrite. It is now a positioned read/write stream. You may change the read/write position with `Wasmex.Pipe.seek()`
* Renamed `Wasmex.Pipe.create()` to `Wasmex.Pipe.new()` to be consistent with other struct-creation calls
* Renamed `Wasmex.Memory.length()` to `Wasmex.Memory.size()` for consistenct with other `size` methods
* Renamed `Wasmex.Memory.set()` to `Wasmex.Memory.set_byte()`
* Renamed `Wasmex.Memory.get()` to `Wasmex.Memory.get_byte()`
* Updated and rewrote most of the docs - all examples are now doctests and tested on CI
* Updated all Elixir/Rust dependencies

## [0.7.1] - 2022-05-25

### Added

- Added an optional fourth parameter to `call_function`, `timeout`, which accepts a value in milliseconds that will cap the execution time of the function. The default behavior if not supplied is preserved, which is a 5 second timeout. Thanks @brooksmtownsend for this contribution


## [0.7.0] - 2022-03-27

### Added

- Added support for precompiled binaries. This should reduce compilation time of wasmex significantly. At the same time it frees most of our users from needing to install Rust. Thanks @fahchen for implementing this feature

### Changed

- Wasmex now aims to support the last three elixir and OTP releases. The oldest supported versions for this release are elixir 1.11.4 and OTP 22.3 - Thanks to @fahchen for contributing the CI workflow to test older elixir/OTP versions
- Moved CI systems from CircleCI to GitHub Actions. Let me thank CircleCI forthe years of free of charge CI runs, thanks! Let me also thank @fahchen for contributing this change
- Thanks to @phaleth for fixing page sizes in our Memory documentation
- Updated several project dependencies, most notably wasmer to 2.1.1

## [0.6.0] - 2021-08-07

### Added

- `Wasmex.Module.compile/1` which compiles a .wasm file into a module. This module can be given to the new methods `Wasmex.Instance.new/2` and `Wasmex.Instance.new_wasi/3` allowing to re-use precompiled modules. This has a big potential speed-up if one wishes to run a WASI instance multiple times. For example, the wasmex test suite went from 14.5s to 0.6s runtime with this release.
- `Wasmex.start_link` can now be called with a precompiled module.
- `Wasmex.Module.compile/1` can now parse WebAssembly text format (WAT) too.
- Wasm modules without exported memory can now be instantiated without error.
- Added the following functions to `Wasmex.Module`:
  - `serialize/1` and `unsafe_deserialize/1` which allows serializing a module into a binary and back
  - `name/1` and `set_name/1` which allows getting/setting a modules name for better debugging
  - `imports/1` and `exports/1` which lists a modules imports and exports

### Deprecated

- `Instance.from_bytes/2` and `Instance.wasi_from_bytes/3` are deprecated in favor of `Wasmex.Instance.new/2` and `Wasmex.Instance.new_wasi/3`. Both may be removed in any release after this one.

## [0.5.0] - 2021-07-22

### Added

- Added WASI support. See [Wasmex.start_link/1](https://hexdocs.pm/wasmex/Wasmex.html#start_link/1) for usage instructions and examples.

```elixir
# after a `wapm install cowsay`
{:ok, bytes } = File.read("wapm_packages/_/cowsay@0.2.0/target/wasm32-wasi/release/cowsay.wasm")
{:ok, stdout} = Wasmex.Pipe.create()
{:ok, stdin} = Wasmex.Pipe.create()
{:ok, instance } = Wasmex.start_link(%{bytes: bytes, wasi: %{stdout: stdout, stdin: stdin}})
Wasmex.Pipe.write(stdin, "Why do you never see elephants hiding in trees? Because they're really good at it.")
{:ok, _} = Wasmex.call_function(instance, :_start, [])
IO.puts Wasmex.Pipe.read(stdout)
  ________________________________________
/ Why do you never see elephants hiding  \
| in trees? Because they're really good  |
\ at it.                                 /
 ----------------------------------------
        \   ^__^
         \  (oo)\_______
            (__)\       )\/\
               ||----w |
                ||     ||
:ok
```

## [0.4.0] - 2021-06-24

### Added

- added support for OTP 24.0 (by updating rustler)

### Changed

- Wasmex.Memory.bytes_per_element changed its signature from
  `Wasmex.Memory.bytes_per_element(memory, :uint32, 0)` to `Wasmex.Memory.bytes_per_element(:uint32)`.
  The existing signature `Wasmex.Memory.bytes_per_element(memory)` still works as before.
- changed the default development branch from `master` to `main`
- targeting and testing on elixir 1.12 and OTP 24.0 now - older versions are likely still working, but will not be tested anymore.

### Removed

- `Wasmex.Memory.grow/4` was removed. Instead `Wasmex.Memory.grow/2` can be used interchangeably.

## [0.3.1] - 2021-04-04

### Added

- added support for `aarch64-darwin` (apple silicon). Thanks @epellis

### Changed

- removed use of `unsafe` from wasm<->elixir value conversion. Thanks @Virviil

## [0.3.0] - 2021-01-09

## Notable Changes

This release features support for elixir function that can be exported to Wasm.

It also supports [the latest wasmer v 1.0](https://medium.com/wasmer/wasmer-1-0-3f86ca18c043) 🎉.
Wasmer 1.0 is a partial rewrite of the Wasm engine we use that promises to be up to 9 times faster module compilation.

### Added

- added the instances first memory into the callback context

```elixir
imports = %{
  env: %{
    read_and_set_memory:
      {:fn, [], [:i32],
        fn context ->
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
- Support writing non-string binaries to memory. Before we could only write valid UTF-8 strings to Wasm memory.
  Thanks again, @myobie, for implementing this feature
- Updated the wasmer version, now supporting wasmer 1.0.
- Updated to elixir 1.11 and Erlang OTP 23.2. Older versions might work, but are not officially tested

### Fixed

- `could not convert callback result param to expected return signature` error for a void callback.

## [0.2.0] - 2020-04-14

This release brings is closer to a production-ready experience.
Calls of WebAssembly functions are now handled asynchronously: Invoking a Wasm function via `Instance.call_exported_function` calls our Rust NIF as before, but does not directly execute the function. Instead, a new OS thread is spawned for the actual execution. This allows us to spend only few time in the NIF code (as required by the Erlang VM). Once the Wasm function in that thread returns, we send a message to the calling erlang process.
To ease handling, we converted our main module `Wasmex` into a `GenServer` so that a Wasm function call can be used in a synchronous manner as before.

### Added

- The `Wasmex` module is now a GenServer. Wasm function calls are now asynchronous.

### Changed

- Removed unused Rust dependencies
- Provide better error messages for `Wasmex.Instance.from_bytes` when the Wasm instance could not be instantiated.
- Wasm function calls now return a list of return values instead of just one value (this is to prepare for Wasm tu officially support multiple return values)
- Updated elixir and rust dependencies including wasmer to version 0.16.2

### Removed

- `Instance.call_exported_function/2` use `Instance.call_exported_function/3` instead.

### Fixed

- Enhanced documentation

## [0.1.0] - 2020-01-15

### Changed

- First release
