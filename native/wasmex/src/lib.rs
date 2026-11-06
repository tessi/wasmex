#[cfg_attr(test, allow(dead_code))]
mod runtime;
#[cfg_attr(test, allow(dead_code))]
pub mod store_executor;

// Rustler registers NIFs through static constructors that reference BEAM symbols.
// Compile only the runtime and executor in standalone Rust tests.
#[cfg(not(test))]
pub mod async_reply;
#[cfg(not(test))]
pub mod atoms;
#[cfg(not(test))]
pub mod caller;
#[cfg(not(test))]
pub mod component;
#[cfg(not(test))]
pub mod component_guest_resource;
#[cfg(not(test))]
mod component_host_resource;
#[cfg(not(test))]
pub mod component_instance;
#[cfg(not(test))]
mod component_type_conversion;
#[cfg(not(test))]
pub mod engine;
#[cfg(not(test))]
pub mod environment;
#[cfg(not(test))]
pub mod functions;
#[cfg(not(test))]
pub mod instance;
#[cfg(not(test))]
pub mod memory;
#[cfg(not(test))]
pub mod module;
#[cfg(not(test))]
pub mod pipe;
#[cfg(not(test))]
pub mod printable_term_type;
#[cfg(not(test))]
pub mod store;
#[cfg(not(test))]
pub mod wat;
#[cfg(not(test))]
pub mod wit;

#[cfg(not(test))]
rustler::init!("Elixir.Wasmex.Native");
