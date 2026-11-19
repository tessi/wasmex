#[cfg_attr(test, allow(dead_code))]
mod runtime;
#[cfg_attr(test, allow(dead_code))]
pub mod store_executor;

// Rustler registers NIFs through static constructors that reference BEAM symbols.
// Exclude NIF registration from standalone Rust tests.
#[cfg(not(test))]
pub mod async_reply;
#[cfg(not(test))]
pub mod atoms;
#[cfg(not(test))]
pub mod caller;
#[cfg(not(test))]
pub mod component;
#[cfg(not(test))]
mod component_call;
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
#[rustler::nif(schedule = "DirtyCpu")]
fn malloc_trim() -> bool {
    #[cfg(all(target_os = "linux", target_env = "gnu"))]
    {
        unsafe extern "C" {
            #[link_name = "malloc_trim"]
            fn glibc_malloc_trim(pad: usize) -> std::ffi::c_int;
        }

        // SAFETY: glibc's malloc_trim is thread-safe and takes only a scalar padding argument.
        unsafe { glibc_malloc_trim(0) == 1 }
    }

    #[cfg(not(all(target_os = "linux", target_env = "gnu")))]
    {
        false
    }
}

#[cfg(not(test))]
rustler::init!("Elixir.Wasmex.Native");
