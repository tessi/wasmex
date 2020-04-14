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

## [Unreleased - 0.2.0]

This release brings is closer to a production-ready experience.
Calls of WebAssembly functions are now handled asynchronously: Invoking a WASM function via `Instance.call_exported_function` calls our Rust NIF as before, but does not directly execute the function. Instead, a new OS thread is spawned for the actual execution. This allows us to spend only few time in the NIF code (as required by the Erlang VM). Once the WASM function in that thread returns, we send a message to the calling erlang process.
To ease handling, we converted our main module `Wasmex` into a `GenServer` so that a WASM function call can be used in a synchronous manner as before.

### Added

- Changed: The Wasmex module is now a GenServer. WASM function calls are now asynchronous
- Removed: Instance.call_exported_function/2 use Instance.call_exported_function/3 instead.
- Fixed: Enhanced documentation
- Changed: Removed unused Rust dependencies
- Provide better error messages for Wasmex.Instance.from_bytes when the WASM instance could not be instantiated.

## [0.1.0] - 2020-01-15

### Changed

- First release
