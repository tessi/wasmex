use crate::store::{ComponentStoreData, ComponentStoreResource};
use rustler::Binary;
use rustler::NifResult;
use rustler::ResourceArc;
use wasmtime::Store;

use std::sync::Mutex;
use wasmtime::component::Component;

pub struct ComponentResource {
    pub inner: Mutex<Component>,
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

    let component = Component::new(store_or_caller.engine(), bytes)
        .map_err(|err| rustler::Error::Term(Box::new(err.to_string())))?;

    Ok(ResourceArc::new(ComponentResource {
        inner: Mutex::new(component),
    }))
}
