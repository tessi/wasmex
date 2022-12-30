//! Memory API of an WebAssembly instance.

use std::io::Write;
use std::sync::Mutex;

use rustler::resource::ResourceArc;
use rustler::{Atom, Binary, Error, NewBinary, NifResult, Term};

use wasmtime::{Instance, Memory, Store};

use crate::environment::{StoreOrCaller, StoreOrCallerResource};
use crate::{atoms, instance};

pub struct MemoryResource {
    pub inner: Mutex<Memory>,
}

#[derive(NifTuple)]
pub struct MemoryResourceResponse {
    ok: rustler::Atom,
    resource: ResourceArc<MemoryResource>,
}

#[rustler::nif(name = "memory_from_instance")]
pub fn from_instance(
    store_or_caller_resource: ResourceArc<StoreOrCallerResource>,
    instance_resource: ResourceArc<instance::InstanceResource>,
) -> rustler::NifResult<MemoryResourceResponse> {
    let instance: Instance = *(instance_resource.inner.lock().map_err(|e| {
        rustler::Error::Term(Box::new(format!(
            "Could not unlock instance resource: {}",
            e
        )))
    })?);
    let store_or_caller: &mut StoreOrCaller =
        &mut *(store_or_caller_resource.inner.lock().map_err(|e| {
            rustler::Error::Term(Box::new(format!(
                "Could not unlock store_or_caller resource: {}",
                e
            )))
        })?);
    let memory = memory_from_instance(&instance, store_or_caller)?;
    let resource = ResourceArc::new(MemoryResource {
        inner: Mutex::new(memory.to_owned()),
    });

    Ok(MemoryResourceResponse {
        ok: atoms::ok(),
        resource,
    })
}

#[rustler::nif(name = "memory_length")]
pub fn length(
    store_or_caller_resource: ResourceArc<StoreOrCallerResource>,
    memory_resource: ResourceArc<MemoryResource>,
) -> NifResult<usize> {
    let store_or_caller: &StoreOrCaller =
        &*(store_or_caller_resource.inner.try_lock().map_err(|e| {
            rustler::Error::Term(Box::new(format!("Could not unlock store resource: {}", e)))
        })?);
    let memory = memory_resource.inner.lock().map_err(|e| {
        rustler::Error::Term(Box::new(format!("Could not unlock memory resource: {}", e)))
    })?;
    let length = memory.data_size(store_or_caller);
    Ok(length)
}

#[rustler::nif(name = "memory_grow")]
pub fn grow(
    store_or_caller_resource: ResourceArc<StoreOrCallerResource>,
    memory_resource: ResourceArc<MemoryResource>,
    pages: u64,
) -> NifResult<u64> {
    let store_or_caller: &mut StoreOrCaller =
        &mut *(store_or_caller_resource.inner.try_lock().map_err(|e| {
            rustler::Error::Term(Box::new(format!(
                "Could not unlock store_or_caller resource: {}",
                e
            )))
        })?);
    let memory = memory_resource.inner.lock().map_err(|e| {
        rustler::Error::Term(Box::new(format!("Could not unlock memory resource: {}", e)))
    })?;
    let store = match store_or_caller {
        StoreOrCaller::Store(store) => store,
        StoreOrCaller::Caller(_) => {
            return Err(Error::Term(Box::new("Cannot grow memory from caller")))
        }
    };
    let old_pages = grow_by_pages(&memory, store, pages)?;
    Ok(old_pages)
}

/// Grows the memory by the given amount of pages. Returns the old page count.
fn grow_by_pages<T>(
    memory: &Memory,
    store: &mut Store<T>,
    number_of_pages: u64,
) -> Result<u64, Error> {
    memory
        .grow(store, number_of_pages)
        .map_err(|err| Error::Term(Box::new(format!("Failed to grow the memory: {}.", err))))
}

#[rustler::nif(name = "memory_get_byte")]
pub fn get_byte(
    store_or_caller_resource: ResourceArc<StoreOrCallerResource>,
    memory_resource: ResourceArc<MemoryResource>,
    index: usize,
) -> NifResult<u8> {
    let store_or_caller = &*(store_or_caller_resource.inner.try_lock().map_err(|e| {
        rustler::Error::Term(Box::new(format!("Could not unlock store resource: {}", e)))
    })?);
    let memory: &Memory = &*(memory_resource.inner.lock().map_err(|e| {
        rustler::Error::Term(Box::new(format!("Could not unlock memory resource: {}", e)))
    })?);

    let mut buffer = [0];
    memory
        .read(store_or_caller, index, &mut buffer)
        .map_err(|err| Error::Term(Box::new(err.to_string())))?;

    Ok(buffer[0])
}

#[rustler::nif(name = "memory_set_byte")]
pub fn set_byte(
    store_or_caller_resource: ResourceArc<StoreOrCallerResource>,
    memory_resource: ResourceArc<MemoryResource>,
    index: usize,
    value: Term,
) -> NifResult<Atom> {
    let store_or_caller = &mut *(store_or_caller_resource.inner.try_lock().map_err(|e| {
        rustler::Error::Term(Box::new(format!("Could not unlock store resource: {}", e)))
    })?);
    let memory: &Memory = &*(memory_resource.inner.lock().map_err(|e| {
        rustler::Error::Term(Box::new(format!("Could not unlock memory resource: {}", e)))
    })?);
    let value = value.decode()?;
    memory
        .write(store_or_caller, index, &[value])
        .map_err(|err| Error::Term(Box::new(err.to_string())))?;

    Ok(atoms::ok())
}

pub fn memory_from_instance(
    instance: &Instance,
    store_or_caller: &mut StoreOrCaller,
) -> Result<Memory, Error> {
    instance
        .exports(store_or_caller)
        .find_map(|export| export.into_memory())
        .ok_or_else(|| Error::Term(Box::new("The WebAssembly module has no exported memory.")))
}

#[rustler::nif(name = "memory_read_binary")]
pub fn read_binary(
    env: rustler::Env,
    store_or_caller_resource: ResourceArc<StoreOrCallerResource>,
    memory_resource: ResourceArc<MemoryResource>,
    index: usize,
    len: usize,
) -> NifResult<Binary> {
    let store_or_caller: &StoreOrCaller =
        &*(store_or_caller_resource.inner.try_lock().map_err(|e| {
            rustler::Error::Term(Box::new(format!(
                "Could not unlock store_or_caller resource: {}",
                e
            )))
        })?);
    let memory: &Memory = &*(memory_resource.inner.lock().map_err(|e| {
        rustler::Error::Term(Box::new(format!("Could not unlock memory resource: {}", e)))
    })?);
    let mut buffer = vec![0u8; len];

    memory
        .read(store_or_caller, index, &mut buffer)
        .map_err(|err| Error::Term(Box::new(err.to_string())))?;

    let mut binary = NewBinary::new(env, len);
    binary.as_mut_slice().write_all(&buffer).unwrap();

    Ok(binary.into())
}

#[rustler::nif(name = "memory_write_binary")]
pub fn write_binary(
    store_or_caller_resource: ResourceArc<StoreOrCallerResource>,
    memory_resource: ResourceArc<MemoryResource>,
    index: usize,
    binary: Binary,
) -> NifResult<Atom> {
    let store_or_caller: &mut StoreOrCaller =
        &mut *(store_or_caller_resource.inner.try_lock().map_err(|e| {
            rustler::Error::Term(Box::new(format!(
                "Could not unlock store_or_caller resource: {}",
                e
            )))
        })?);
    let memory: &Memory = &*(memory_resource.inner.lock().map_err(|e| {
        rustler::Error::Term(Box::new(format!("Could not unlock memory resource: {}", e)))
    })?);
    memory
        .write(store_or_caller, index, binary.as_slice())
        .map_err(|err| Error::Term(Box::new(err.to_string())))?;

    Ok(atoms::ok())
}
