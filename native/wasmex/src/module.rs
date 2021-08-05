use rustler::{resource::ResourceArc, types::binary::Binary, Atom, NifResult, OwnedBinary};
use std::sync::Mutex;

use wasmer::{wat2wasm, Module, Store};

use crate::atoms;

pub struct ModuleResource {
    pub module: Mutex<Module>,
}

#[derive(NifTuple)]
pub struct ModuleResourceResponse {
    ok: rustler::Atom,
    resource: ResourceArc<ModuleResource>,
}

#[rustler::nif(name = "module_compile")]
pub fn compile(binary: Binary) -> NifResult<ModuleResourceResponse> {
    let bytes = binary.as_slice();
    let bytes = wat2wasm(bytes).map_err(|e| {
        rustler::Error::Term(Box::new(format!("Error while parsing bytes: {}.", e)))
    })?;
    let store = Store::default();
    match Module::new(&store, bytes) {
        Ok(module) => {
            let resource = ResourceArc::new(ModuleResource {
                module: Mutex::new(module),
            });
            Ok(ModuleResourceResponse {
                ok: atoms::ok(),
                resource,
            })
        }
        Err(e) => Err(rustler::Error::Term(Box::new(format!(
            "Could not compile module: {:?}",
            e
        )))),
    }
}

#[rustler::nif(name = "module_name")]
pub fn name(resource: ResourceArc<ModuleResource>) -> NifResult<String> {
    let module = resource.module.lock().map_err(|e| {
        rustler::Error::Term(Box::new(format!(
            "Could not unlock module resource as the mutex was poisoned: {}",
            e
        )))
    })?;
    let name = module
        .name()
        .ok_or_else(|| rustler::Error::Term(Box::new("no module name set")))?;
    Ok(name.into())
}

#[rustler::nif(name = "module_set_name")]
pub fn set_name(resource: ResourceArc<ModuleResource>, new_name: String) -> NifResult<Atom> {
    let mut module = resource.module.lock().map_err(|e| {
        rustler::Error::Term(Box::new(format!(
            "Could not unlock module resource as the mutex was poisoned: {}",
            e
        )))
    })?;
    if module.set_name(&new_name) {
        Ok(atoms::ok())
    } else {
        Err(rustler::Error::Term(Box::new(
            "Could not change module name. Maybe it is already instantiated?",
        )))
    }
}

#[rustler::nif(name = "module_serialize")]
pub fn serialize(env: rustler::Env, resource: ResourceArc<ModuleResource>) -> NifResult<Binary> {
    let module = resource.module.lock().map_err(|e| {
        rustler::Error::Term(Box::new(format!(
            "Could not unlock module resource as the mutex was poisoned: {}",
            e
        )))
    })?;
    let serialized_module: Vec<u8> = module.serialize().map_err(|e| {
        rustler::Error::Term(Box::new(format!("Could not serialize module: {}", e)))
    })?;
    let mut binary = OwnedBinary::new(serialized_module.len())
        .ok_or_else(|| rustler::Error::Term(Box::new("not enough memory")))?;
    binary.copy_from_slice(&serialized_module);
    Ok(binary.release(env))
}

#[rustler::nif(name = "module_unsafe_deserialize")]
pub fn unsafe_deserialize(binary: Binary) -> NifResult<ModuleResourceResponse> {
    let store = Store::default();
    // Safety: This function is inherently unsafe as the provided bytes:
    // 1. Are going to be deserialized directly into Rust objects.
    // 2. Contains the function assembly bodies and, if intercepted, a malicious actor could inject code into executable memory.
    // And as such, the deserialize method is unsafe.
    // However, there isn't much we can do about it here, we will warn users in elixir-land about this, though.
    let module = unsafe {
        Module::deserialize(&store, binary.as_slice()).map_err(|e| {
            rustler::Error::Term(Box::new(format!("Could not deserialize module: {}", e)))
        })?
    };
    let resource = ResourceArc::new(ModuleResource {
        module: Mutex::new(module),
    });
    Ok(ModuleResourceResponse {
        ok: atoms::ok(),
        resource,
    })
}
