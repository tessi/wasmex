//! Memory API of an WebAssembly instance.

use wasmer_runtime::Memory as WasmMemory;
use wasmer_runtime_core::units::Pages;

use rustler::{Env, Encoder, Error, Term};
use rustler::resource::ResourceArc;
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
  Int32
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
  let size = term.atom_to_string().map_err(|_| {
    Error::RaiseTerm(Box::new("Must be given a valid size atom."))
  })?;
  let size = match size.as_str() {
    "uint8" => ElementSize::Uint8,
    "int8" => ElementSize::Int8,
    "uint16" => ElementSize::Uint16,
    "int16" => ElementSize::Int16,
    "uint32" => ElementSize::Uint32,
    "int32" => ElementSize::Int32,
    _ => return Err(Error::RaiseTerm(Box::new("Size must be one of `uint8`, `int8`, `uint16`, `int16`, `uint32`, `int32`."))),
  };
  Ok(size)
}

pub fn bytes_per_element<'a>(env: Env<'a>, args: &[Term<'a>]) -> Result<Term<'a>, Error> {
  Ok(atoms::ok().encode(env))
}

pub fn length<'a>(env: Env<'a>, args: &[Term<'a>]) -> Result<Term<'a>, Error> {
  Ok(atoms::ok().encode(env))
}

pub fn get<'a>(env: Env<'a>, args: &[Term<'a>]) -> Result<Term<'a>, Error> {
  Ok(atoms::ok().encode(env))
}

pub fn set<'a>(env: Env<'a>, args: &[Term<'a>]) -> Result<Term<'a>, Error> {
  Ok(atoms::ok().encode(env))
}

fn memory(instance: runtime::Instance) -> Result<runtime::Memory, Error> {
  instance
    .exports()
    .find_map(|(_, export)| match export {
        Export::Memory(memory) => Some(memory),
        _ => None,
    })
    .ok_or_else(|| {
        Error::RaiseTerm(Box::new("The WebAssembly module has no exported memory."))
    })
}