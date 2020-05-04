//! Memory API of an WebAssembly instance.

use std::sync::Mutex;

use rustler::resource::ResourceArc;
use rustler::{Encoder, Env, Error, Term};
use wasmer_runtime::{self as runtime, Export, Memory};
use wasmer_runtime_core::units::Pages;

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

pub fn from_instance<'a>(env: Env<'a>, args: &[Term<'a>]) -> Result<Term<'a>, Error> {
    let instance_resource: ResourceArc<instance::InstanceResource> = args[0].decode()?;
    let instance = instance_resource.instance.lock().unwrap();
    let memory = memory_from_instance(&*instance)?;
    let memory_resource = ResourceArc::new(MemoryResource {
        memory: Mutex::new(memory),
    });

    Ok((atoms::ok(), memory_resource).encode(env))
}

fn size_from_term(term: &Term) -> Result<ElementSize, Error> {
    let size = term
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

pub fn bytes_per_element<'a>(env: Env<'a>, args: &[Term<'a>]) -> Result<Term<'a>, Error> {
    let (_resource, size, _offset) = extract_params(args)?;
    let bytes_count = byte_size(size);
    Ok(bytes_count.encode(env))
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

pub fn length<'a>(env: Env<'a>, args: &[Term<'a>]) -> Result<Term<'a>, Error> {
    let (resource, size, offset) = extract_params(args)?;
    let memory = resource.memory.lock().unwrap();
    let length = view_length(&memory, offset, size);
    Ok(length.encode(env))
}

fn extract_params<'a>(
    args: &[Term<'a>],
) -> Result<(ResourceArc<MemoryResource>, ElementSize, usize), Error> {
    let resource: ResourceArc<MemoryResource> = args[0].decode()?;
    let size = size_from_term(&args[1])?;
    let offset = args[2].decode()?;
    Ok((resource, size, offset))
}

fn view_length(memory: &runtime::Memory, offset: usize, element_size: ElementSize) -> usize {
    match element_size {
        ElementSize::Uint8 => memory.view::<u8>()[offset..].len(),
        ElementSize::Int8 => memory.view::<i8>()[offset..].len(),
        ElementSize::Uint16 => memory.view::<u16>()[offset..].len(),
        ElementSize::Int16 => memory.view::<i16>()[offset..].len(),
        ElementSize::Uint32 => memory.view::<u32>()[offset..].len(),
        ElementSize::Int32 => memory.view::<i32>()[offset..].len(),
    }
}

pub fn grow<'a>(env: Env<'a>, args: &[Term<'a>]) -> Result<Term<'a>, Error> {
    let (resource, _size, _offset) = extract_params(args)?;
    let pages: u32 = args[3].decode()?;

    let memory = resource.memory.lock().unwrap();
    let old_pages = grow_by_pages(&memory, pages)?;
    Ok(old_pages.encode(env))
}

/// Grows the memory by the given amount of pages. Returns the old page count.
fn grow_by_pages(memory: &runtime::Memory, number_of_pages: u32) -> Result<u32, Error> {
    memory
        .grow(Pages(number_of_pages))
        .map(|previous_pages| previous_pages.0)
        .map_err(|err| Error::RaiseTerm(Box::new(format!("Failed to grow the memory: {}.", err))))
}

pub fn get<'a>(env: Env<'a>, args: &[Term<'a>]) -> Result<Term<'a>, Error> {
    let (resource, size, offset) = extract_params(args)?;
    let memory = resource.memory.lock().unwrap();
    let index: usize = args[3].decode()?;
    let index = bounds_checked_index(&memory, size, offset, index)?;

    Ok(get_value(&env, &memory, offset, index, size))
}

fn get_value<'a>(
    env: &Env<'a>,
    memory: &runtime::Memory,
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

pub fn set<'a>(env: Env<'a>, args: &[Term<'a>]) -> Result<Term<'a>, Error> {
    let (resource, size, offset) = extract_params(args)?;
    let memory = resource.memory.lock().unwrap();
    let index: usize = args[3].decode()?;
    let index = bounds_checked_index(&memory, size, offset, index)?;

    set_value(&memory, offset, index, size, args[4])?;
    Ok(atoms::ok().encode(env))
}

fn set_value<'a>(
    memory: &runtime::Memory,
    offset: usize,
    index: usize,
    element_size: ElementSize,
    value: Term<'a>,
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
    memory: &runtime::Memory,
    size: ElementSize,
    offset: usize,
    index: usize,
) -> Result<usize, Error> {
    let length = view_length(&memory, offset, size);
    if length <= index {
        return Err(Error::RaiseTerm(Box::new(format!(
            "Out of bound: Given index {} is larger than the memory size {}.",
            index, length
        ))));
    }
    Ok(index)
}

fn memory_from_instance(instance: &runtime::Instance) -> Result<runtime::Memory, Error> {
    instance
        .exports()
        .find_map(|(_, export)| match export {
            Export::Memory(memory) => Some(memory),
            _ => None,
        })
        .ok_or_else(|| Error::RaiseTerm(Box::new("The WebAssembly module has no exported memory.")))
}

pub fn read_binary<'a>(env: Env<'a>, args: &[Term<'a>]) -> Result<Term<'a>, Error> {
    let (resource, size, offset) = extract_params(args)?;
    let memory = resource.memory.lock().unwrap();
    let index: usize = args[3].decode()?;
    let index = bounds_checked_index(&memory, size, offset, index)?;
    let view = memory.view::<u8>();

    if offset + index >= view.len() {
        return Err(Error::RaiseTerm(Box::new(
            "Out of bound: The given binary will write out of memory",
        )));
    }

    let mut binary: Vec<u8> = Vec::new();
    for i in (offset + index)..view.len() {
        let value = view[i].get();
        binary.push(value);
        if value == 0 {
            break;
        }
    }
    Ok(binary.encode(env))
}

pub fn write_binary<'a>(env: Env<'a>, args: &[Term<'a>]) -> Result<Term<'a>, Error> {
    let (resource, size, offset) = extract_params(args)?;
    let memory = resource.memory.lock().unwrap();
    let index: usize = args[3].decode()?;
    let index = bounds_checked_index(&memory, size, offset, index)?;
    let binary: String = args[4].decode()?;
    let view = memory.view::<u8>();

    if offset + index + binary.len() > view.len() {
        return Err(Error::RaiseTerm(Box::new(
            "Out of bound: The given binary will write out of memory",
        )));
    }

    for (i, byte) in binary.into_bytes().into_iter().enumerate() {
        view[offset + index + i].set(byte)
    }
    Ok(atoms::ok().encode(env))
}
