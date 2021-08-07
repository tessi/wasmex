//! Memory API of an WebAssembly instance.

use std::sync::Mutex;

use rustler::resource::ResourceArc;
use rustler::{Atom, Binary, Encoder, Env as RustlerEnv, Error, NifResult, OwnedBinary, Term};

use wasmer::{Extern, Instance, Memory, Pages};

use crate::{atoms, instance};

pub struct MemoryResource {
    pub memory: Mutex<Memory>,
}

#[derive(Debug, Copy, Clone)]
pub enum ElementSize {
    Uint8,
    Int8,
    Uint16,
    Int16,
    Uint32,
    Int32,
}

#[derive(NifTuple)]
pub struct MemoryResourceResponse {
    ok: rustler::Atom,
    resource: ResourceArc<MemoryResource>,
}

#[rustler::nif(name = "memory_from_instance")]
pub fn from_instance(
    instance_resource: ResourceArc<instance::InstanceResource>,
) -> rustler::NifResult<MemoryResourceResponse> {
    let instance = instance_resource.instance.lock().unwrap();
    let memory = memory_from_instance(&*instance)?;
    let resource = ResourceArc::new(MemoryResource {
        memory: Mutex::new(memory.to_owned()),
    });

    Ok(MemoryResourceResponse {
        ok: atoms::ok(),
        resource,
    })
}

fn size_from_term(size: &Term) -> Result<ElementSize, Error> {
    let size = size
        .atom_to_string()
        .map_err(|_| Error::RaiseTerm(Box::new("Must be given a valid size atom.")))?;
    let size = match size.as_str() {
        "uint8" => ElementSize::Uint8,
        "int8" => ElementSize::Int8,
        "uint16" => ElementSize::Uint16,
        "int16" => ElementSize::Int16,
        "uint32" => ElementSize::Uint32,
        "int32" => ElementSize::Int32,
        _ => {
            return Err(Error::RaiseTerm(Box::new(
                "Size must be one of `uint8`, `int8`, `uint16`, `int16`, `uint32`, `int32`.",
            )))
        }
    };
    Ok(size)
}

#[rustler::nif(name = "memory_bytes_per_element")]
pub fn bytes_per_element(size: Term) -> NifResult<usize> {
    let size = size_from_term(&size)?;
    Ok(byte_size(size))
}

fn byte_size(element_size: ElementSize) -> usize {
    match element_size {
        ElementSize::Uint8 => 1,
        ElementSize::Int8 => 1,
        ElementSize::Uint16 => 2,
        ElementSize::Int16 => 2,
        ElementSize::Uint32 => 4,
        ElementSize::Int32 => 4,
    }
}

#[rustler::nif(name = "memory_length")]
pub fn length(
    resource: ResourceArc<MemoryResource>,
    size: Term,
    offset: usize,
) -> NifResult<usize> {
    let size = size_from_term(&size)?;
    let memory = resource.memory.lock().unwrap();
    let length = view_length(&memory, offset, size);
    Ok(length)
}

fn view_length(memory: &Memory, offset: usize, element_size: ElementSize) -> usize {
    match element_size {
        ElementSize::Uint8 => memory.view::<u8>()[offset..].len(),
        ElementSize::Int8 => memory.view::<i8>()[offset..].len(),
        ElementSize::Uint16 => memory.view::<u16>()[offset..].len(),
        ElementSize::Int16 => memory.view::<i16>()[offset..].len(),
        ElementSize::Uint32 => memory.view::<u32>()[offset..].len(),
        ElementSize::Int32 => memory.view::<i32>()[offset..].len(),
    }
}

#[rustler::nif(name = "memory_grow")]
pub fn grow(resource: ResourceArc<MemoryResource>, pages: u32) -> NifResult<u32> {
    let memory = resource.memory.lock().unwrap();
    let old_pages = grow_by_pages(&memory, pages)?;
    Ok(old_pages)
}

/// Grows the memory by the given amount of pages. Returns the old page count.
fn grow_by_pages(memory: &Memory, number_of_pages: u32) -> Result<u32, Error> {
    memory
        .grow(Pages(number_of_pages))
        .map(|previous_pages| previous_pages.0)
        .map_err(|err| Error::RaiseTerm(Box::new(format!("Failed to grow the memory: {}.", err))))
}

#[rustler::nif(name = "memory_get")]
pub fn get<'a>(
    env: rustler::Env<'a>,
    resource: ResourceArc<MemoryResource>,
    size: Term<'a>,
    offset: usize,
    index: usize,
) -> NifResult<Term<'a>> {
    let memory = resource.memory.lock().unwrap();
    let size = size_from_term(&size)?;
    let index = bounds_checked_index(&memory, size, offset, index)?;

    Ok(get_value(&env, &memory, offset, index, size))
}

fn get_value<'a>(
    env: &RustlerEnv<'a>,
    memory: &Memory,
    offset: usize,
    index: usize,
    element_size: ElementSize,
) -> Term<'a> {
    let i = offset + index;
    match element_size {
        ElementSize::Uint8 => memory.view::<u8>()[i].get().encode(*env),
        ElementSize::Int8 => memory.view::<i8>()[i].get().encode(*env),
        ElementSize::Uint16 => memory.view::<u16>()[i].get().encode(*env),
        ElementSize::Int16 => memory.view::<i16>()[i].get().encode(*env),
        ElementSize::Uint32 => memory.view::<u32>()[i].get().encode(*env),
        ElementSize::Int32 => memory.view::<i32>()[i].get().encode(*env),
    }
}

#[rustler::nif(name = "memory_set")]
pub fn set<'a>(
    resource: ResourceArc<MemoryResource>,
    size: Term<'a>,
    offset: usize,
    index: usize,
    value: Term<'a>,
) -> NifResult<Atom> {
    let memory = resource.memory.lock().unwrap();
    let size = size_from_term(&size)?;
    let index = bounds_checked_index(&memory, size, offset, index)?;

    set_value(&memory, offset, index, size, value)?;
    Ok(atoms::ok())
}

fn set_value(
    memory: &Memory,
    offset: usize,
    index: usize,
    element_size: ElementSize,
    value: Term,
) -> Result<(), Error> {
    match element_size {
        ElementSize::Uint8 => memory.view::<u8>()[offset + index].set(value.decode::<u8>()?),
        ElementSize::Int8 => memory.view::<i8>()[offset + index].set(value.decode::<i8>()?),
        ElementSize::Uint16 => memory.view::<u16>()[offset + index].set(value.decode::<u16>()?),
        ElementSize::Int16 => memory.view::<i16>()[offset + index].set(value.decode::<i16>()?),
        ElementSize::Uint32 => memory.view::<u32>()[offset + index].set(value.decode::<u32>()?),
        ElementSize::Int32 => memory.view::<i32>()[offset + index].set(value.decode::<i32>()?),
    }
    Ok(())
}

fn bounds_checked_index(
    memory: &Memory,
    size: ElementSize,
    offset: usize,
    index: usize,
) -> Result<usize, Error> {
    let len = view_length(memory, offset, size);
    if len <= index {
        return Err(Error::RaiseTerm(Box::new(format!(
            "Out of bound: Given index {} is larger than the memory size {}.",
            index, len
        ))));
    }
    Ok(index)
}

pub fn memory_from_instance(instance: &Instance) -> Result<&Memory, Error> {
    instance
        .exports
        .iter()
        .find_map(|(_, export)| match export {
            Extern::Memory(memory) => Some(memory),
            _ => None,
        })
        .ok_or_else(|| Error::RaiseTerm(Box::new("The WebAssembly module has no exported memory.")))
}

#[rustler::nif(name = "memory_read_binary")]
pub fn read_binary<'a>(
    env: rustler::Env<'a>,
    resource: ResourceArc<MemoryResource>,
    size: Term<'a>,
    offset: usize,
    index: usize,
    len: usize,
) -> NifResult<Binary<'a>> {
    let memory = resource.memory.lock().unwrap();
    let size = size_from_term(&size)?;
    let index = bounds_checked_index(&memory, size, offset, index)?;
    let view = memory.view::<u8>();

    let start = offset + index;
    let end = offset + index + len;

    if end > view.len() {
        return Err(Error::RaiseTerm(Box::new(
            "Out of bound: The given binary will read out of memory",
        )));
    }

    let mut binary: OwnedBinary = OwnedBinary::new(len).unwrap();

    let data = view[start..end]
        .iter()
        .map(|cell| cell.get())
        .collect::<Vec<u8>>();

    binary.copy_from_slice(&data);
    Ok(binary.release(env))
}

#[rustler::nif(name = "memory_write_binary")]
pub fn write_binary(
    resource: ResourceArc<MemoryResource>,
    size: Term,
    offset: usize,
    index: usize,
    binary: Binary,
) -> NifResult<Atom> {
    let memory = resource.memory.lock().unwrap();
    let size = size_from_term(&size)?;
    let index = bounds_checked_index(&memory, size, offset, index)?;
    let view = memory.view::<u8>();

    if offset + index + binary.len() > view.len() {
        return Err(Error::RaiseTerm(Box::new(
            "Out of bound: The given binary will write out of memory",
        )));
    }

    for (i, byte) in binary.iter().enumerate() {
        view[offset + index + i].set(*byte)
    }
    Ok(atoms::ok())
}
