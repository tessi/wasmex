//! Memory API of a WebAssembly instance.

use crate::{
    async_reply::{submit_error, AsyncReply},
    atoms,
    caller::CallerCommand,
    instance,
    store::{StoreOrCallerResource, StoreTarget},
};
use rustler::{Atom, Binary, ResourceArc, Term};
use wasmtime::{Instance, Memory};

pub struct MemoryResource {
    pub inner: Memory,
}

#[rustler::resource_impl()]
impl rustler::Resource for MemoryResource {}

fn clone_memory(resource: &MemoryResource) -> Memory {
    resource.inner
}

#[rustler::nif(name = "memory_from_instance")]
pub fn from_instance(
    store_or_caller_resource: ResourceArc<StoreOrCallerResource>,
    instance_resource: ResourceArc<instance::InstanceResource>,
    from: Term,
) -> Result<Atom, rustler::Error> {
    let instance = instance_resource.inner;
    let reply = AsyncReply::new(from)?;

    match store_or_caller_resource.target()? {
        StoreTarget::Executor(executor) => {
            let submit_reply = AsyncReply::new(from)?;
            if let Err(error) = executor.submit(move |mut store| async move {
                match memory_from_instance(&instance, &mut store) {
                    Ok(memory) => reply.send(ResourceArc::new(MemoryResource { inner: memory })),
                    Err(error) => reply.send_error(error),
                }
                store
            }) {
                submit_error(submit_reply, error);
            }
        }
        StoreTarget::Caller(session) => {
            let command = CallerCommand::MemoryFromInstance { instance, reply };
            if let Err(error) = session.submit(command) {
                error.reject();
            }
        }
    }
    Ok(atoms::ok())
}

#[rustler::nif(name = "memory_size")]
pub fn size(
    store_or_caller_resource: ResourceArc<StoreOrCallerResource>,
    memory_resource: ResourceArc<MemoryResource>,
    from: Term,
) -> Result<Atom, rustler::Error> {
    let memory = clone_memory(&memory_resource);
    let reply = AsyncReply::new(from)?;

    match store_or_caller_resource.target()? {
        StoreTarget::Executor(executor) => {
            let submit_reply = AsyncReply::new(from)?;
            if let Err(error) = executor.submit(move |store| async move {
                reply.send(memory.data_size(&store));
                store
            }) {
                submit_error(submit_reply, error);
            }
        }
        StoreTarget::Caller(session) => {
            let command = CallerCommand::MemorySize { memory, reply };
            if let Err(error) = session.submit(command) {
                error.reject();
            }
        }
    }
    Ok(atoms::ok())
}

#[rustler::nif(name = "memory_grow")]
pub fn grow(
    store_or_caller_resource: ResourceArc<StoreOrCallerResource>,
    memory_resource: ResourceArc<MemoryResource>,
    pages: u64,
    from: Term,
) -> Result<Atom, rustler::Error> {
    let memory = clone_memory(&memory_resource);
    let reply = AsyncReply::new(from)?;

    match store_or_caller_resource.target()? {
        StoreTarget::Executor(executor) => {
            let submit_reply = AsyncReply::new(from)?;
            if let Err(error) = executor.submit(move |mut store| async move {
                match memory.grow(&mut store, pages) {
                    Ok(old_pages) => reply.send(old_pages),
                    Err(error) => reply.send_error(format!("Failed to grow the memory: {error}.")),
                }
                store
            }) {
                submit_error(submit_reply, error);
            }
        }
        StoreTarget::Caller(_) => reply.send_error("Cannot grow memory from caller"),
    }
    Ok(atoms::ok())
}

#[rustler::nif(name = "memory_get_byte")]
pub fn get_byte(
    store_or_caller_resource: ResourceArc<StoreOrCallerResource>,
    memory_resource: ResourceArc<MemoryResource>,
    index: usize,
    from: Term,
) -> Result<Atom, rustler::Error> {
    let memory = clone_memory(&memory_resource);
    let reply = AsyncReply::new(from)?;

    match store_or_caller_resource.target()? {
        StoreTarget::Executor(executor) => {
            let submit_reply = AsyncReply::new(from)?;
            if let Err(error) = executor.submit(move |store| async move {
                let mut buffer = [0];
                match memory.read(&store, index, &mut buffer) {
                    Ok(()) => reply.send(buffer[0]),
                    Err(error) => reply.send_error(error.to_string()),
                }
                store
            }) {
                submit_error(submit_reply, error);
            }
        }
        StoreTarget::Caller(session) => {
            let command = CallerCommand::MemoryGetByte {
                memory,
                index,
                reply,
            };
            if let Err(error) = session.submit(command) {
                error.reject();
            }
        }
    }
    Ok(atoms::ok())
}

#[rustler::nif(name = "memory_set_byte")]
pub fn set_byte(
    store_or_caller_resource: ResourceArc<StoreOrCallerResource>,
    memory_resource: ResourceArc<MemoryResource>,
    index: usize,
    value: u8,
    from: Term,
) -> Result<Atom, rustler::Error> {
    let memory = clone_memory(&memory_resource);
    let reply = AsyncReply::new(from)?;

    match store_or_caller_resource.target()? {
        StoreTarget::Executor(executor) => {
            let submit_reply = AsyncReply::new(from)?;
            if let Err(error) = executor.submit(move |mut store| async move {
                match memory.write(&mut store, index, &[value]) {
                    Ok(()) => reply.send(atoms::ok()),
                    Err(error) => reply.send_error(error.to_string()),
                }
                store
            }) {
                submit_error(submit_reply, error);
            }
        }
        StoreTarget::Caller(session) => {
            let command = CallerCommand::MemorySetByte {
                memory,
                index,
                value,
                reply,
            };
            if let Err(error) = session.submit(command) {
                error.reject();
            }
        }
    }
    Ok(atoms::ok())
}

pub fn memory_from_instance<T: wasmtime::AsContextMut>(
    instance: &Instance,
    mut store: T,
) -> Result<Memory, String> {
    instance
        .exports(&mut store)
        .find_map(|export| export.into_memory())
        .ok_or_else(|| "The WebAssembly module has no exported memory.".to_string())
}

#[rustler::nif(name = "memory_read_binary")]
pub fn read_binary(
    store_or_caller_resource: ResourceArc<StoreOrCallerResource>,
    memory_resource: ResourceArc<MemoryResource>,
    index: usize,
    len: usize,
    from: Term,
) -> Result<Atom, rustler::Error> {
    let memory = clone_memory(&memory_resource);
    let reply = AsyncReply::new(from)?;

    match store_or_caller_resource.target()? {
        StoreTarget::Executor(executor) => {
            let submit_reply = AsyncReply::new(from)?;
            if let Err(error) = executor.submit(move |store| async move {
                let mut buffer = vec![0u8; len];
                match memory.read(&store, index, &mut buffer) {
                    Ok(()) => reply.send_binary(buffer),
                    Err(error) => reply.send_error(error.to_string()),
                }
                store
            }) {
                submit_error(submit_reply, error);
            }
        }
        StoreTarget::Caller(session) => {
            let command = CallerCommand::MemoryRead {
                memory,
                index,
                len,
                reply,
            };
            if let Err(error) = session.submit(command) {
                error.reject();
            }
        }
    }
    Ok(atoms::ok())
}

#[rustler::nif(name = "memory_write_binary")]
pub fn write_binary(
    store_or_caller_resource: ResourceArc<StoreOrCallerResource>,
    memory_resource: ResourceArc<MemoryResource>,
    index: usize,
    binary: Binary,
    from: Term,
) -> Result<Atom, rustler::Error> {
    let memory = clone_memory(&memory_resource);
    let bytes = binary.as_slice().to_vec();
    let reply = AsyncReply::new(from)?;

    match store_or_caller_resource.target()? {
        StoreTarget::Executor(executor) => {
            let submit_reply = AsyncReply::new(from)?;
            if let Err(error) = executor.submit(move |mut store| async move {
                match memory.write(&mut store, index, &bytes) {
                    Ok(()) => reply.send(atoms::ok()),
                    Err(error) => reply.send_error(error.to_string()),
                }
                store
            }) {
                submit_error(submit_reply, error);
            }
        }
        StoreTarget::Caller(session) => {
            let command = CallerCommand::MemoryWrite {
                memory,
                index,
                bytes,
                reply,
            };
            if let Err(error) = session.submit(command) {
                error.reject();
            }
        }
    }
    Ok(atoms::ok())
}
