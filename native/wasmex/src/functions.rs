use wasmer_runtime::{self as runtime};

pub fn exists(instance: &runtime::Instance, name: &str) -> bool {
    find(instance, &name).is_ok()
}

pub fn find<'a>(
    instance: &'a runtime::Instance,
    name: &str,
) -> Result<wasmer_runtime_core::instance::DynFunc<'a>, wasmer_runtime_core::error::ResolveError> {
    instance.exports.get(name)
}
