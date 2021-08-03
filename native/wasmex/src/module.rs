use rustler::{resource::ResourceArc, types::binary::Binary, NifResult, OwnedBinary};
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

#[rustler::nif(name = "module_serialize")]
pub fn serialize(env: rustler::Env, resource: ResourceArc<ModuleResource>) -> NifResult<Binary> {
    let module = resource.module.lock().map_err(|e| {
        rustler::Error::Term(Box::new(format!(
            "Could not unlock module resource as the mutex was poisoned: {}",
            e
        )))
    })?;
    let mut serialized_module = module.serialize().map_err(|e| {
        rustler::Error::Term(Box::new(format!(
            "Could not unlock module resource as the mutex was poisoned: {}",
            e
        )))
    })?;
    let mut owned_binary = OwnedBinary::new(serialized_module.len()).ok_or_else(|| {
        rustler::Error::Term(Box::new(
            "could not allocate enough memory to serialize module",
        ))
    })?;
    owned_binary.swap_with_slice(serialized_module.as_mut_slice());
    Ok(owned_binary.release(env))
}

#[rustler::nif(name = "module_deserialize")]
pub fn deserialize(binary: Binary) -> NifResult<ModuleResourceResponse> {
    let store = Store::default();
    // Safety: This function is inherently unsafe as the provided bytes:
    // 1. Are going to be deserialized directly into Rust objects.
    // 2. Contains the function assembly bodies and, if intercepted, a malicious actor could inject code into executable memory.
    // And as such, the deserialize method is unsafe.
    // However, there isn't much we can do about it here, we will warn users in elixir-land about this, though.
    let module = unsafe {
        Module::deserialize(&store, &binary).map_err(|e| {
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
