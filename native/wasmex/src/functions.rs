use wasmer_runtime::{self as runtime};

pub fn exists(instance: &runtime::Instance, name: &String) -> bool {
  find(instance, &name).is_ok()
}

pub fn find<'a>(instance: &'a runtime::Instance, name: &String) -> Result<wasmer_runtime_core::instance::DynFunc<'a>, wasmer_runtime_core::error::ResolveError> {
  instance.dyn_func(&name)
}
