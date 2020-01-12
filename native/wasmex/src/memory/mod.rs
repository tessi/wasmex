//! Memory API of an WebAssembly instance.

use wasmer_runtime::Memory as WasmMemory;
use wasmer_runtime_core::units::Pages;

use rustler::resource::ResourceArc;
use rustler::{Encoder, Env, Error, Term};
use wasmer_runtime::{self as runtime, Export};

use crate::{atoms, instance};
pub struct MemoryResource {
    pub instance: ResourceArc<instance::InstanceResource>,
    pub size: ElementSize,
    pub offset: usize,
}

pub enum ElementSize {
    Uint8,
    Int8,
    Uint16,
    Int16,
    Uint32,
    Int32,
}

pub fn from_instance<'a>(env: Env<'a>, args: &[Term<'a>]) -> Result<Term<'a>, Error> {
    let instance: ResourceArc<instance::InstanceResource> = args[0].decode()?;
    let size = size_from_term(&args[1])?;
    let offset: usize = args[2].decode()?;

    let memory_resource = ResourceArc::new(MemoryResource {
        instance,
        size,
        offset,
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
    let resource: ResourceArc<MemoryResource> = args[0].decode()?;
    let bytes_count = byte_size(&resource.size);
    Ok(bytes_count.encode(env))
}

fn byte_size(element_size: &ElementSize) -> usize {
    match *element_size {
        ElementSize::Uint8 => 1,
        ElementSize::Int8 => 1,
        ElementSize::Uint16 => 2,
        ElementSize::Int16 => 2,
        ElementSize::Uint32 => 4,
        ElementSize::Int32 => 4,
    }
}

pub fn length<'a>(env: Env<'a>, args: &[Term<'a>]) -> Result<Term<'a>, Error> {
    let resource: ResourceArc<MemoryResource> = args[0].decode()?;
    let instance = resource.instance.instance.lock().unwrap();
    let memory = memory_from_instance(&instance)?;
    let length = byte_length(&memory, resource.offset, &resource.size);
    Ok(length.encode(env))
}

fn byte_length(memory: &runtime::Memory, offset: usize, element_size: &ElementSize) -> usize {
    match *element_size {
        ElementSize::Uint8 => memory.view::<u8>()[offset..].len(),
        ElementSize::Int8 => memory.view::<i8>()[offset..].len(),
        ElementSize::Uint16 => memory.view::<u16>()[offset..].len(),
        ElementSize::Int16 => memory.view::<i16>()[offset..].len(),
        ElementSize::Uint32 => memory.view::<u32>()[offset..].len(),
        ElementSize::Int32 => memory.view::<i32>()[offset..].len(),
    }
}

pub fn grow<'a>(env: Env<'a>, args: &[Term<'a>]) -> Result<Term<'a>, Error> {
    let resource: ResourceArc<MemoryResource> = args[0].decode()?;
    let pages: u32 = args[1].decode()?;

    let instance = resource.instance.instance.lock().unwrap();
    let memory = memory_from_instance(&instance)?;
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
    Ok(atoms::ok().encode(env))
}

pub fn set<'a>(env: Env<'a>, args: &[Term<'a>]) -> Result<Term<'a>, Error> {
    Ok(atoms::ok().encode(env))
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
