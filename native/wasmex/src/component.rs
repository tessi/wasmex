use crate::store::{StoreOrCaller, StoreOrCallerResource};
use rustler::Binary;
use rustler::NifResult;
use rustler::ResourceArc;
use rustler::Error;

use std::sync::Mutex;
use wasmtime::component::{Component, Instance, Linker};

pub struct ComponentResource {
    pub inner: Mutex<Component>,
}

#[rustler::resource_impl()]
impl rustler::Resource for ComponentResource {}

#[rustler::nif(name = "component_new")]
pub fn new_component(
    store_or_caller_resource: ResourceArc<StoreOrCallerResource>,
    component_binary: Binary,
) -> NifResult<ResourceArc<ComponentResource>> {
    let store_or_caller: &mut StoreOrCaller =
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

#[rustler::nif(name = "component_instance_new")]
pub fn new_component_instance(
    store_or_caller_resource: ResourceArc<StoreOrCallerResource>,
    component_resource: ResourceArc<ComponentResource>,
) -> NifResult<ResourceArc<ComponentInstanceResource>> {
    let store_or_caller: &mut StoreOrCaller =
        &mut *(store_or_caller_resource.inner.lock().map_err(|e| {
            rustler::Error::Term(Box::new(format!(
                "Could not unlock store_or_caller resource as the mutex was poisoned: {e}"
            )))
        })?);

    let component = &mut component_resource.inner.lock().map_err(|e| {
        rustler::Error::Term(Box::new(format!(
            "Could not unlock component resource as the mutex was poisoned: {e}"
        )))
    })?;

    let linker = Linker::new(store_or_caller.engine());

    // Instantiate the component
    let instance = linker
        .instantiate(&mut *store_or_caller, &component)
        .map_err(|err| Error::Term(Box::new(err.to_string())))?;

    Ok(ResourceArc::new(ComponentInstanceResource {
        inner: Mutex::new(instance),
    }))
}

pub struct ComponentInstanceResource {
    pub inner: Mutex<Instance>,
}

#[rustler::resource_impl()]
impl rustler::Resource for ComponentInstanceResource {}
