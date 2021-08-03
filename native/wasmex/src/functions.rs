use wasmer::{ExportError, Function, Instance};

pub fn exists(instance: &Instance, name: &str) -> bool {
    find(instance, name).is_ok()
}

pub fn find<'a>(instance: &'a Instance, name: &str) -> Result<&'a Function, ExportError> {
    instance.exports.get(name)
}
