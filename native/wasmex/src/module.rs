use crate::{
    atoms,
    engine::{unwrap_engine, EngineResource},
    store::{StoreOrCaller, StoreOrCallerResource},
};
use rustler::{
    types::tuple::make_tuple, Binary, Encoder, Env, NifResult, OwnedBinary, ResourceArc, Term,
};
use std::{collections::HashMap, sync::Mutex};
use wasmtime::{
    ExternType, FuncType, GlobalType, MemoryType, Module, Mutability, RefType, TableType, ValType,
};

pub struct ModuleResource {
    pub inner: Mutex<Module>,
}

#[rustler::resource_impl()]
impl rustler::Resource for ModuleResource {}

#[rustler::nif(name = "module_compile", schedule = "DirtyCpu")]
pub fn compile(
    store_or_caller_resource: ResourceArc<StoreOrCallerResource>,
    binary: Binary,
) -> Result<ResourceArc<ModuleResource>, rustler::Error> {
    let store_or_caller: &mut StoreOrCaller =
        &mut *(store_or_caller_resource.inner.lock().map_err(|e| {
            rustler::Error::Term(Box::new(format!(
                "Could not unlock store_or_caller resource as the mutex was poisoned: {e}"
            )))
        })?);
    let bytes = binary.as_slice();
    let bytes = wat::parse_bytes(bytes)
        .map_err(|e| rustler::Error::Term(Box::new(format!("Error while parsing bytes: {e}."))))?;
    match Module::new(store_or_caller.engine(), bytes) {
        Ok(module) => {
            let resource = ResourceArc::new(ModuleResource {
                inner: Mutex::new(module),
            });
            Ok(resource)
        }
        Err(e) => Err(rustler::Error::Term(Box::new(format!(
            "Could not compile module: {e:?}"
        )))),
    }
}

#[rustler::nif(name = "module_name")]
pub fn name(module_resource: ResourceArc<ModuleResource>) -> NifResult<String> {
    let module = module_resource.inner.lock().map_err(|e| {
        rustler::Error::Term(Box::new(format!(
            "Could not unlock module resource as the mutex was poisoned: {e}"
        )))
    })?;
    let name = module
        .name()
        .ok_or_else(|| rustler::Error::Term(Box::new("no module name set")))?;
    Ok(name.into())
}

#[rustler::nif(name = "module_exports")]
pub fn exports(env: rustler::Env, module_resource: ResourceArc<ModuleResource>) -> NifResult<Term> {
    let module = module_resource.inner.lock().map_err(|e| {
        rustler::Error::Term(Box::new(format!(
            "Could not unlock module resource as the mutex was poisoned: {e}"
        )))
    })?;
    let mut map = rustler::Term::map_new(env);
    for export in module.exports() {
        let export_name = rustler::Encoder::encode(export.name(), env);
        let export_info = match export.ty() {
            ExternType::Func(ty) => function_info(env, &ty),
            ExternType::Global(ty) => global_info(env, &ty),
            ExternType::Memory(ty) => memory_info(env, &ty),
            ExternType::Table(ty) => table_info(env, &ty),
            ExternType::Tag(ty) => tag_info(env, &ty),
        };
        map = map.map_put(export_name, export_info)?;
    }
    Ok(map)
}

#[rustler::nif(name = "module_imports")]
pub fn imports(env: rustler::Env, module_resource: ResourceArc<ModuleResource>) -> NifResult<Term> {
    let module = module_resource.inner.lock().map_err(|e| {
        rustler::Error::Term(Box::new(format!(
            "Could not unlock module resource as the mutex was poisoned: {e}"
        )))
    })?;
    let mut namespaces = HashMap::new();
    for import in module.imports() {
        let import_name = rustler::Encoder::encode(import.name(), env);
        let import_module = String::from(import.module());

        let import_info = match import.ty() {
            ExternType::Func(ty) => function_info(env, &ty),
            ExternType::Global(ty) => global_info(env, &ty),
            ExternType::Table(ty) => table_info(env, &ty),
            ExternType::Memory(ty) => memory_info(env, &ty),
            ExternType::Tag(ty) => tag_info(env, &ty),
        };
        let map = namespaces
            .entry(import_module)
            .or_insert_with(|| rustler::Term::map_new(env));
        *map = map.map_put(import_name, import_info)?;
    }
    let mut map = rustler::Term::map_new(env);
    for (module_name, &module_map) in &namespaces {
        let module_name = rustler::Encoder::encode(&module_name, env);
        map = map.map_put(module_name, module_map)?;
    }
    Ok(map)
}

enum WasmValueType {
    I32,
    I64,
    F32,
    F64,
    V128,
    Ref(String),
}

impl Encoder for WasmValueType {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        match self {
            Self::I32 => atoms::i32().encode(env),
            Self::I64 => atoms::i64().encode(env),
            Self::F32 => atoms::f32().encode(env),
            Self::F64 => atoms::f64().encode(env),
            Self::V128 => atoms::v128().encode(env),
            Self::Ref(ref_type) => (atoms::reference(), ref_type).encode(env),
        }
    }
}

impl From<&ValType> for WasmValueType {
    fn from(val_type: &ValType) -> Self {
        match val_type {
            ValType::I32 => Self::I32,
            ValType::I64 => Self::I64,
            ValType::F32 => Self::F32,
            ValType::F64 => Self::F64,
            ValType::V128 => Self::V128,
            ValType::Ref(ref_type) => Self::Ref(ref_type.to_string()),
        }
    }
}

impl From<&RefType> for WasmValueType {
    fn from(ref_type: &RefType) -> Self {
        Self::Ref(ref_type.to_string())
    }
}

fn function_info<'a>(env: rustler::Env<'a>, ty: &FuncType) -> Term<'a> {
    let params = ty
        .params()
        .fold(Term::list_new_empty(env), |acc, ref param_type| {
            let typ: WasmValueType = param_type.into();
            acc.list_prepend(typ.encode(env))
        });
    let params = params
        .list_reverse()
        .expect("cannot fail, its always a list");
    let results = ty
        .results()
        .fold(Term::list_new_empty(env), |acc, ref param_type| {
            let typ: WasmValueType = param_type.into();
            acc.list_prepend(typ.encode(env))
        });
    let results = results
        .list_reverse()
        .expect("cannot fail, its always a list");
    let terms = vec![atoms::__fn__().to_term(env), params, results];
    make_tuple(env, &terms)
}

fn global_info<'a>(env: rustler::Env<'a>, global_type: &GlobalType) -> Term<'a> {
    let mut map = rustler::Term::map_new(env);
    match global_type.mutability() {
        Mutability::Const => {
            map = map
                .map_put(
                    atoms::mutability().to_term(env),
                    atoms::__const__().to_term(env),
                )
                .expect("cannot fail; is always a map")
        }
        Mutability::Var => {
            map = map
                .map_put(atoms::mutability().to_term(env), atoms::var().to_term(env))
                .expect("cannot fail; is always a map")
        }
    }
    let ty: WasmValueType = global_type.content().into();
    map = map
        .map_put(atoms::__type__().to_term(env), ty.encode(env))
        .expect("cannot fail; is always a map");
    let terms = vec![atoms::global().to_term(env), map];
    make_tuple(env, &terms)
}

fn tag_info<'a>(env: rustler::Env<'a>, tag_type: &wasmtime::TagType) -> Term<'a> {
    let params = tag_type
        .ty()
        .params()
        .fold(Term::list_new_empty(env), |acc, ref param_type| {
            let typ: WasmValueType = param_type.into();
            acc.list_prepend(typ.encode(env))
        });
    let params = params
        .list_reverse()
        .expect("cannot fail, its always a list");
    let results = tag_type
        .ty()
        .results()
        .fold(Term::list_new_empty(env), |acc, ref param_type| {
            let typ: WasmValueType = param_type.into();
            acc.list_prepend(typ.encode(env))
        });
    let results = results
        .list_reverse()
        .expect("cannot fail, its always a list");
    let terms = vec![atoms::tag().to_term(env), params, results];
    make_tuple(env, &terms)
}

fn table_info<'a>(env: rustler::Env<'a>, table_type: &TableType) -> Term<'a> {
    let mut map = rustler::Term::map_new(env);
    if let Some(i) = table_type.maximum() {
        map = map
            .map_put(
                atoms::maximum().to_term(env),
                rustler::Encoder::encode(&i, env),
            )
            .expect("cannot fail; is always a map");
    }
    map = map
        .map_put(
            atoms::minimum().to_term(env),
            rustler::Encoder::encode(&table_type.minimum(), env),
        )
        .expect("cannot fail; is always a map");
    let ty: WasmValueType = table_type.element().into();
    map = map
        .map_put(atoms::__type__().to_term(env), ty)
        .expect("cannot fail; is always a map");
    let terms = vec![atoms::table().to_term(env), map];
    make_tuple(env, &terms)
}

fn memory_info<'a>(env: rustler::Env<'a>, memory_type: &MemoryType) -> Term<'a> {
    let mut map = rustler::Term::map_new(env);
    if let Some(maximum) = memory_type.maximum() {
        map = map
            .map_put(
                atoms::maximum().to_term(env),
                rustler::Encoder::encode(&maximum, env),
            )
            .expect("cannot fail; is always a map");
    }
    map = map
        .map_put(
            atoms::minimum().to_term(env),
            rustler::Encoder::encode(&memory_type.minimum(), env),
        )
        .expect("cannot fail; is always a map");
    map = map
        .map_put(
            atoms::shared().to_term(env),
            rustler::Encoder::encode(&memory_type.is_shared(), env),
        )
        .expect("cannot fail; is always a map");
    map = map
        .map_put(
            atoms::memory64().to_term(env),
            rustler::Encoder::encode(&memory_type.is_64(), env),
        )
        .expect("cannot fail; is always a map");
    let terms: Vec<Term> = vec![atoms::memory().to_term(env), map];
    make_tuple(env, &terms)
}

#[rustler::nif(name = "module_serialize", schedule = "DirtyCpu")]
pub fn serialize(
    env: rustler::Env,
    module_resource: ResourceArc<ModuleResource>,
) -> NifResult<Binary> {
    let module = module_resource.inner.lock().map_err(|e| {
        rustler::Error::Term(Box::new(format!(
            "Could not unlock module resource as the mutex was poisoned: {e}"
        )))
    })?;
    let serialized_module: Vec<u8> = module
        .serialize()
        .map_err(|e| rustler::Error::Term(Box::new(format!("Could not serialize module: {e}"))))?;
    let mut binary = OwnedBinary::new(serialized_module.len())
        .ok_or_else(|| rustler::Error::Term(Box::new("not enough memory")))?;
    binary.copy_from_slice(&serialized_module);
    Ok(binary.release(env))
}

#[rustler::nif(name = "module_unsafe_deserialize", schedule = "DirtyCpu")]
pub fn unsafe_deserialize(
    binary: Binary,
    engine_resource: ResourceArc<EngineResource>,
) -> Result<ResourceArc<ModuleResource>, rustler::Error> {
    let engine = unwrap_engine(engine_resource)?;
    // Safety: This function is inherently unsafe as the provided bytes:
    // 1. Are going to be deserialized directly into Rust objects.
    // 2. Contains the function assembly bodies and, if intercepted, a malicious actor could inject code into executable memory.
    // And as such, the deserialize method is unsafe.
    // However, there isn't much we can do about it here, we will warn users in elixir-land about this, though.
    let module = unsafe {
        Module::deserialize(&engine, binary.as_slice()).map_err(|e| {
            rustler::Error::Term(Box::new(format!("Could not deserialize module: {e}")))
        })?
    };
    let resource = ResourceArc::new(ModuleResource {
        inner: Mutex::new(module),
    });
    Ok(resource)
}
