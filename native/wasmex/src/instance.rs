use std::sync::Mutex;
use rustler::{Env, Encoder, Error, Term};
use rustler::resource::ResourceArc;
use rustler::types::binary::Binary;
use wasmer_runtime::{self as runtime, imports};

use crate::atoms;

pub struct InstanceResource {
    pub instance: Mutex<runtime::Instance>,
}

pub fn new_from_bytes<'a>(env: Env<'a>, args: &[Term<'a>]) -> Result<Term<'a>, Error> {
    let binary: Binary = args[0].decode()?;
    let bytes = binary.as_slice();

    let import_object = imports! {};
    let instance = runtime::instantiate(bytes, &import_object).map_err(|_| Error::Atom("could_not_instantiate"))?;

    // assign memory
    // assign exported functions

    let resource = ResourceArc::new(InstanceResource { instance: Mutex::new(instance) });
    Ok((atoms::ok(), resource).encode(env))
}
