#[macro_use]
extern crate rustler;

use std::sync::Mutex;
use rustler::{Encoder, Env, Error, Term};
use rustler::resource::ResourceArc;
use rustler::types::binary::Binary;
use wasmer_runtime::{self as runtime, imports};

mod atoms {
    rustler::rustler_atoms! {
        atom ok;
        //atom error;
        //atom __true__ = "true";
        //atom __false__ = "false";
    }
}

struct InstanceResource {
    pub instance: Mutex<runtime::Instance>,
}

rustler::rustler_export_nifs! {
    "Elixir.Wasmex.Native",
    [
        ("instance_new_from_bytes", 1, instance_new_from_bytes)
    ],
    Some(on_load)
}

fn on_load(env: Env, _info: Term) -> bool {
    resource_struct_init!(InstanceResource, env);
    true
}

fn instance_new_from_bytes<'a>(env: Env<'a>, args: &[Term<'a>]) -> Result<Term<'a>, Error> {
    let binary: Binary = args[0].decode()?;
    let bytes = binary.as_slice();

    let import_object = imports! {};
    let instance = runtime::instantiate(bytes, &import_object).map_err(|_| Error::Atom("could_not_instantiate"))?;

    // assign memory
    // assign exported functions

    let resource = ResourceArc::new(InstanceResource { instance: Mutex::new(instance) });
    Ok((atoms::ok(), resource).encode(env))
}
