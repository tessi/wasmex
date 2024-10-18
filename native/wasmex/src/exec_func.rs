use crate::component::ComponentInstanceResource;
use crate::component::ComponentResource;
use crate::store::ComponentStoreData;
use crate::store::ComponentStoreResource;
use crate::store::{StoreOrCaller, StoreOrCallerResource};

use rustler::Error;
use rustler::ResourceArc;

use wasmtime::component::Linker;
use wasmtime::Store;

// This is an obviously silly hardcoded stub POC. It will call a function by name in the
// passed component reference, but assumes (this is the silly part) that said function
// takes no arguments and returns a list of strings. See wasm_component_test.exs
#[rustler::nif(name = "exec_func")]
pub fn exec_func_impl(
    component_store_resource: ResourceArc<ComponentStoreResource>,
    instance_resource: ResourceArc<ComponentInstanceResource>,
    func_name: String,
) -> Result<Vec<String>, rustler::Error> {
    let component_store: &mut Store<ComponentStoreData> =
        &mut *(component_store_resource.inner.lock().map_err(|e| {
            rustler::Error::Term(Box::new(format!(
                "Could not unlock component_store resource as the mutex was poisoned: {e}"
            )))
        })?);

    let instance = &mut instance_resource.inner.lock().map_err(|e| {
        rustler::Error::Term(Box::new(format!(
            "Could not unlock component instance resource as the mutex was poisoned: {e}"
        )))
    })?;

    let func = instance
        .get_func(&mut *component_store, func_name)
        .expect("init not found");

    let typed = func
        .typed::<(), (Vec<String>,)>(&mut *component_store)
        .map_err(|err| Error::Term(Box::new(err.to_string())))?;

    let (result,) = typed
        .call(&mut *component_store, ())
        .map_err(|err| Error::Term(Box::new(err.to_string())))?;

    Ok(result)
}
