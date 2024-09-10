use crate::engine::{unwrap_engine, EngineResource};
use crate::store::{StoreOrCaller, StoreOrCallerResource};

use rustler::Error;
use rustler::ResourceArc;
use wasmtime::component::{Component, Linker};

// #[rustler::nif](name="bob")
// pub fn bob_says() ->
#[rustler::nif(name = "todo_init")]
pub fn todo_init_impl(
    store_or_caller_resource: ResourceArc<StoreOrCallerResource>,
) -> Result<Vec<String>, rustler::Error> {
    let store_or_caller: &mut StoreOrCaller =
        &mut *(store_or_caller_resource.inner.lock().map_err(|e| {
            rustler::Error::Term(Box::new(format!(
                "Could not unlock store_or_caller resource as the mutex was poisoned: {e}"
            )))
        })?);

    // Load the component from disk
    let bytes =
        std::fs::read("./todo-list.wasm").map_err(|err| Error::Term(Box::new(err.to_string())))?;
    let component =
        Component::new(store_or_caller.engine(), bytes).map_err(|err| Error::Term(Box::new(err.to_string())))?;

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
