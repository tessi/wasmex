
use wasmex::component::ComponentResource;
use wasmex::store::{StoreOrCaller, StoreOrCallerResource};
use rustler::ResourceArc;
use rustler::NifResult;
use wasmtime::component::{Linker, bindgen};
use std::sync::Mutex;

bindgen!("todo-list" in "todo-list.wit");

pub struct TodoListResource {
    pub inner: Mutex<TodoList>,
}

#[rustler::resource_impl()]
impl rustler::Resource for TodoListResource {}

#[rustler::nif(name = "instantiate")]
pub fn instantiate(
    store_or_caller_resource: ResourceArc<StoreOrCallerResource>,
    component_resource: ResourceArc<ComponentResource>,
) -> NifResult<ResourceArc<TodoListResource>> {
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
    let todo_instance = TodoList::instantiate(store_or_caller, &component, &linker)
        .map_err(|err| rustler::Error::Term(Box::new(err.to_string())))?;

    Ok(ResourceArc::new(TodoListResource {
        inner: Mutex::new(todo_instance),
    }))
}

#[rustler::nif(name = "init")]
pub fn init(
    store_or_caller_resource: ResourceArc<StoreOrCallerResource>,
    todo_list_resource: ResourceArc<TodoListResource>,
) -> NifResult<Vec<String>> {
    let store_or_caller: &mut StoreOrCaller =
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

    
    todo_list.call_init(store_or_caller).map_err(|err| rustler::Error::Term(Box::new(err.to_string())))
}

fn my_load(env: rustler::Env, _term: rustler::Term) -> bool {
  true
}
rustler::init!("Elixir.TodoList", load = my_load);
