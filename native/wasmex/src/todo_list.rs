use crate::component::ComponentResource;
use crate::store::{
    ComponentStoreData, ComponentStoreResource, StoreOrCaller, StoreOrCallerResource,
};
use rustler::NifResult;
use rustler::ResourceArc;
use std::sync::Mutex;
use wasmtime::component::{bindgen, Linker};
use wasmtime::{Config, Engine, Store};

bindgen!("todo-list" in "todo-list.wit");

pub struct TodoListResource {
    pub inner: Mutex<TodoList>,
}

#[rustler::resource_impl()]
impl rustler::Resource for TodoListResource {}

#[rustler::nif(name = "todo_instantiate")]
pub fn instantiate(
    component_store_resource: ResourceArc<ComponentStoreResource>,
    component_resource: ResourceArc<ComponentResource>,
) -> NifResult<ResourceArc<TodoListResource>> {
    let component_store: &mut Store<ComponentStoreData> =
        &mut *(component_store_resource.inner.lock().map_err(|e| {
            rustler::Error::Term(Box::new(format!(
                "Could not unlock component_store resource as the mutex was poisoned: {e}"
            )))
        })?);

    let component = &mut component_resource.inner.lock().map_err(|e| {
        rustler::Error::Term(Box::new(format!(
            "Could not unlock component resource as the mutex was poisoned: {e}"
        )))
    })?;

    let mut config = Config::new();
    config.wasm_component_model(true);
    config.async_support(true);
    let engine = Engine::new(&config).unwrap();

    let mut linker = Linker::new(&engine);
    wasmtime_wasi::add_to_linker_sync(&mut linker);
    wasmtime_wasi_http::add_only_http_to_linker_sync(&mut linker);
    let todo_instance = TodoList::instantiate(component_store, &component, &linker)
        .map_err(|err| rustler::Error::Term(Box::new(err.to_string())))?;

    Ok(ResourceArc::new(TodoListResource {
        inner: Mutex::new(todo_instance),
    }))
}

#[rustler::nif(name = "todo_init")]
pub fn init(
    store_or_caller_resource: ResourceArc<ComponentStoreResource>,
    todo_list_resource: ResourceArc<TodoListResource>,
) -> NifResult<Vec<String>> {
    let store_or_caller: &mut Store<ComponentStoreData> =
        &mut *(store_or_caller_resource.inner.lock().map_err(|e| {
            rustler::Error::Term(Box::new(format!(
                "Could not unlock store_or_caller resource as the mutex was poisoned: {e}"
            )))
        })?);

    let todo_list = &mut todo_list_resource.inner.lock().map_err(|e| {
        rustler::Error::Term(Box::new(format!(
            "Could not unlock todo_list resource as the mutex was poisoned: {e}"
        )))
    })?;

    todo_list
        .call_init(store_or_caller)
        .map_err(|err| rustler::Error::Term(Box::new(err.to_string())))
}
