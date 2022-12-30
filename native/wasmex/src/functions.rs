use wasmtime::Func;
use wasmtime::Instance;

use crate::environment::StoreOrCaller;

pub fn exists(instance: &Instance, store_or_caller: &mut StoreOrCaller, name: &str) -> bool {
    find(instance, store_or_caller, name).is_some()
}

pub fn find(instance: &Instance, store_or_caller: &mut StoreOrCaller, name: &str) -> Option<Func> {
    instance.get_func(store_or_caller, name)
}
