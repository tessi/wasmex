use crate::engine::{unwrap_engine, EngineResource};
use crate::store::ComponentStoreResource;
use rustler::{Binary, Env, Error, NifResult, OwnedBinary, ResourceArc};
use wasmtime::component::Component;
use wit_parser::decoding::DecodedWasm;

pub struct ComponentResource {
    pub inner: Component,
}

#[rustler::resource_impl()]
impl rustler::Resource for ComponentResource {}

#[rustler::nif(name = "component_new", schedule = "DirtyCpu")]
pub fn new_component(
    store_or_caller_resource: ResourceArc<ComponentStoreResource>,
    component_binary: Binary,
) -> NifResult<ResourceArc<ComponentResource>> {
    let executor = store_or_caller_resource.executor()?;
    let bytes = component_binary.as_slice();
    let decoded_wasm = wit_parser::decoding::decode(bytes)
        .map_err(|e| Error::Term(Box::new(format!("Unable to decode WASM: {e}"))))?;
    if matches!(decoded_wasm, DecodedWasm::WitPackage(_, _)) {
        return Err(Error::RaiseAtom("Only components are supported"));
    }

    let inner = Component::new(executor.engine(), bytes)
        .map_err(|err| Error::Term(Box::new(err.to_string())))?;
    Ok(ResourceArc::new(ComponentResource { inner }))
}

#[rustler::nif(name = "component_serialize", schedule = "DirtyCpu")]
pub fn serialize(env: Env, component: ResourceArc<ComponentResource>) -> NifResult<Binary> {
    let artifact = component
        .inner
        .serialize()
        .map_err(|err| Error::Term(Box::new(format!("Could not serialize component: {err}"))))?;
    Ok(OwnedBinary::from_slice(&artifact).release(env))
}

#[rustler::nif(name = "component_unsafe_deserialize", schedule = "DirtyCpu")]
pub fn unsafe_deserialize(
    bytes: Binary,
    engine: ResourceArc<EngineResource>,
) -> NifResult<ResourceArc<ComponentResource>> {
    let engine = unwrap_engine(engine)?;
    // SAFETY: The caller must supply an unchanged artifact from a trusted Wasmtime compiler.
    let inner = unsafe { Component::deserialize(&engine, bytes.as_slice()) }
        .map_err(|err| Error::Term(Box::new(format!("Could not deserialize component: {err}"))))?;
    Ok(ResourceArc::new(ComponentResource { inner }))
}
