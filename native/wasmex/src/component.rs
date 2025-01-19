use crate::store::{ComponentStoreData, ComponentStoreResource};
use rustler::Binary;
use rustler::Error;
use rustler::NifResult;
use rustler::ResourceArc;
use wasmtime::Store;
use wit_parser::decoding::DecodedWasm;
use wit_parser::Resolve;
use wit_parser::WorldId;

use std::sync::Mutex;
use wasmtime::component::Component;

pub struct ComponentResource {
    pub inner: Mutex<Component>,
    pub parsed: ParsedComponent,
}

pub struct ParsedComponent {
    pub world_id: WorldId,
    pub resolve: Resolve,
}

#[rustler::resource_impl()]
impl rustler::Resource for ComponentResource {}

#[rustler::nif(name = "component_new")]
pub fn new_component(
    store_or_caller_resource: ResourceArc<ComponentStoreResource>,
    component_binary: Binary,
) -> NifResult<ResourceArc<ComponentResource>> {
    let store_or_caller: &mut Store<ComponentStoreData> =
        &mut *(store_or_caller_resource.inner.lock().map_err(|e| {
            rustler::Error::Term(Box::new(format!(
                "Could not unlock store_or_caller resource as the mutex was poisoned: {e}"
            )))
        })?);
    let bytes = component_binary.as_slice();
    let decoded_wasm = wit_parser::decoding::decode(bytes)
        .map_err(|e| Error::Term(Box::new(format!("Unable to decode WASM: {e}"))))?;
    let parsed_component = match decoded_wasm {
        DecodedWasm::WitPackage(_, _) => {
            return Err(rustler::Error::RaiseAtom("Only components are supported"))
        }
        DecodedWasm::Component(resolve, world_id) => ParsedComponent { world_id, resolve },
    };

    let component = Component::new(store_or_caller.engine(), bytes)
        .map_err(|err| rustler::Error::Term(Box::new(err.to_string())))?;

    Ok(ResourceArc::new(ComponentResource {
        inner: Mutex::new(component),
        parsed: parsed_component,
    }))
}
