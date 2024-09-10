use crate::component::ComponentInstanceResource;
use crate::component::ComponentResource;
use crate::engine::{unwrap_engine, EngineResource};
use crate::store::{StoreOrCaller, StoreOrCallerResource};

use rustler::Binary;
use rustler::Error;
use rustler::ResourceArc;

use wasmtime::component::{Component, Instance, Linker};

// #[rustler::nif](name="bob")
#[rustler::nif(name = "todo_init")]
pub fn todo_init_impl(
    store_or_caller_resource: ResourceArc<StoreOrCallerResource>,
    component_resource: ResourceArc<ComponentResource>,
) -> Result<Vec<String>, rustler::Error> {
    let store_or_caller: &mut StoreOrCaller =
        &mut *(store_or_caller_resource.inner.lock().map_err(|e| {
            rustler::Error::Term(Box::new(format!(
                "Could not unlock store_or_caller resource as the mutex was poisoned: {e}"
            )))
        })?);

    // Load the component from disk
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

    // Call the `greet` function
    let func = instance
        .get_func(&mut *store_or_caller, "init")
        .expect("init not found");

    let typed = func
        .typed::<(), (Vec<String>,)>(&mut *store_or_caller)
        .map_err(|err| Error::Term(Box::new(err.to_string())))?;

    let (result,) = typed
        .call(&mut *store_or_caller, ())
        .map_err(|err| Error::Term(Box::new(err.to_string())))?;

    Ok(result)
}

#[rustler::nif(name = "exec_func")]
pub fn exec_func_impl(
    store_or_caller_resource: ResourceArc<StoreOrCallerResource>,
    instance_resource: ResourceArc<ComponentInstanceResource>,
    func_name: String,
) -> Result<Vec<String>, rustler::Error> {
    let store_or_caller: &mut StoreOrCaller =
        &mut *(store_or_caller_resource.inner.lock().map_err(|e| {
            rustler::Error::Term(Box::new(format!(
                "Could not unlock store_or_caller resource as the mutex was poisoned: {e}"
            )))
        })?);
        
    let instance = &mut instance_resource.inner.lock().map_err(|e| {
        rustler::Error::Term(Box::new(format!(
            "Could not unlock component instance resource as the mutex was poisoned: {e}"
        )))
    })?;

    let func = instance
        .get_func(&mut *store_or_caller, func_name)
        .expect("init not found");

    let typed = func
        .typed::<(), (Vec<String>,)>(&mut *store_or_caller)
        .map_err(|err| Error::Term(Box::new(err.to_string())))?;

    let (result,) = typed
        .call(&mut *store_or_caller, ())
        .map_err(|err| Error::Term(Box::new(err.to_string())))?;

    Ok(result)
}
