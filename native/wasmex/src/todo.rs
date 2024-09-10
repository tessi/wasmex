use crate::engine::{EngineResource, unwrap_engine};
use rustler::ResourceArc;
use rustler::Error;
use wasmtime::component::{Linker, Component};

// #[rustler::nif](name="bob")
// pub fn bob_says() -> 
#[rustler::nif(name = "todo_init")]
pub fn todo_init_impl(engine_resource: ResourceArc<EngineResource>) -> Result<Vec<String>, rustler::Error> {
    let engine = unwrap_engine(engine_resource)?;

    let mut store = wasmtime::Store::new(&engine, ());

    // Load the component from disk
    let bytes = std::fs::read("./todo-list.wasm").map_err(|err| Error::Term(Box::new(err.to_string())))?;
    let component = Component::new(&engine, bytes).map_err(|err| Error::Term(Box::new(err.to_string())))?;

    let linker = Linker::new(&engine);

    // Instantiate the component
    let instance = linker.instantiate(&mut store, &component).map_err(|err| Error::Term(Box::new(err.to_string())))?;

    // Call the `greet` function
    let func = instance.get_func(&mut store, "init").expect("init not found");

    let typed = func.typed::<(), (Vec<String>,)>(&store).map_err(|err| Error::Term(Box::new(err.to_string())))?;

    let (result,) = typed.call(store, ()).map_err(|err| Error::Term(Box::new(err.to_string())))?;

    Ok(result)
}
