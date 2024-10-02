use crate::component::ComponentInstanceResource;
use crate::component::ComponentResource;
use crate::store::{StoreOrCaller, StoreOrCallerResource};

use rustler::Error;
use rustler::ResourceArc;

use wasmtime::component::Linker;

// This is an obviously silly hardcoded stub POC. It will call a function by name in the 
// passed component reference, but assumes (this is the silly part) that said function 
// takes no arguments and returns a list of strings. See wasm_component_test.exs
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
