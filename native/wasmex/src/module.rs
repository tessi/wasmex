use rustler::{
    resource::ResourceArc,
    types::{binary::Binary, tuple::make_tuple},
    Atom, NifResult, OwnedBinary, Term,
};
use std::{collections::HashMap, sync::Mutex};

use wasmtime::{
    Engine, ExternType, FuncType, GlobalType, MemoryType, Module, Mutability, TableType, ValType,
};

use crate::{
    atoms,
    environment::{StoreOrCaller, StoreOrCallerResource},
};

pub struct ModuleResource {
    pub inner: Mutex<Module>,
}

#[derive(NifTuple)]
pub struct ModuleResourceResponse {
    ok: rustler::Atom,
    resource: ResourceArc<ModuleResource>,
}

#[rustler::nif(name = "module_compile")]
pub fn compile(
    store_or_caller_resource: ResourceArc<StoreOrCallerResource>,
    binary: Binary,
) -> NifResult<ModuleResourceResponse> {
    let store_or_caller: &mut StoreOrCaller =
        &mut *(store_or_caller_resource.inner.lock().map_err(|e| {
            rustler::Error::Term(Box::new(format!(
                "Could not unlock store_or_caller resource as the mutex was poisoned: {}",
                e
            )))
        })?);
    let bytes = binary.as_slice();
    let bytes = wat::parse_bytes(bytes).map_err(|e| {
        rustler::Error::Term(Box::new(format!("Error while parsing bytes: {}.", e)))
    })?;
    match Module::new(store_or_caller.engine(), bytes) {
        Ok(module) => {
            let resource = ResourceArc::new(ModuleResource {
                inner: Mutex::new(module),
            });
            Ok(ModuleResourceResponse {
                ok: atoms::ok(),
                resource,
            })
        }
        Err(e) => Err(rustler::Error::Term(Box::new(format!(
            "Could not compile module: {:?}",
            e
        )))),
    }
}

#[rustler::nif(name = "module_name")]
pub fn name(module_resource: ResourceArc<ModuleResource>) -> NifResult<String> {
    let module = module_resource.inner.lock().map_err(|e| {
        rustler::Error::Term(Box::new(format!(
            "Could not unlock module resource as the mutex was poisoned: {}",
            e
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
            "Could not unlock module resource as the mutex was poisoned: {}",
            e
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
        };
        map = map.map_put(export_name, export_info)?;
    }
    Ok(map)
}

#[rustler::nif(name = "module_imports")]
pub fn imports(env: rustler::Env, module_resource: ResourceArc<ModuleResource>) -> NifResult<Term> {
    let module = module_resource.inner.lock().map_err(|e| {
        rustler::Error::Term(Box::new(format!(
            "Could not unlock module resource as the mutex was poisoned: {}",
            e
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

fn function_info<'a>(env: rustler::Env<'a>, ty: &FuncType) -> Term<'a> {
    let params = ty
        .params()
        .fold(Term::list_new_empty(env), |acc, param_type| {
            acc.list_prepend(val_type_to_atom(&param_type).to_term(env))
        });
    let params = params
        .list_reverse()
        .expect("cannot fail, its always a list");
    let results = ty
        .results()
        .fold(Term::list_new_empty(env), |acc, param_type| {
            acc.list_prepend(val_type_to_atom(&param_type).to_term(env))
        });
    let results = results
        .list_reverse()
        .expect("cannot fail, its always a list");
    let terms = vec![atoms::__fn__().to_term(env), params, results];
    make_tuple(env, &terms)
}

fn val_type_to_atom(val_type: &ValType) -> Atom {
    match val_type {
        ValType::I32 => atoms::i32(),
        ValType::I64 => atoms::i64(),
        ValType::F32 => atoms::f32(),
        ValType::F64 => atoms::f64(),
        ValType::V128 => atoms::v128(),
        ValType::ExternRef => atoms::extern_ref(),
        ValType::FuncRef => atoms::func_ref(),
    }
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
    let ty = val_type_to_atom(global_type.content()).to_term(env);
    map = map
        .map_put(atoms::__type__().to_term(env), ty)
        .expect("cannot fail; is always a map");
    let terms = vec![atoms::global().to_term(env), map];
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
    let ty = val_type_to_atom(&table_type.element()).to_term(env);
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

#[rustler::nif(name = "module_serialize")]
pub fn serialize(
    env: rustler::Env,
    module_resource: ResourceArc<ModuleResource>,
) -> NifResult<Binary> {
    let module = module_resource.inner.lock().map_err(|e| {
        rustler::Error::Term(Box::new(format!(
            "Could not unlock module resource as the mutex was poisoned: {}",
            e
        )))
    })?;
    let serialized_module: Vec<u8> = module.serialize().map_err(|e| {
        rustler::Error::Term(Box::new(format!("Could not serialize module: {}", e)))
    })?;
    let mut binary = OwnedBinary::new(serialized_module.len())
        .ok_or_else(|| rustler::Error::Term(Box::new("not enough memory")))?;
    binary.copy_from_slice(&serialized_module);
    Ok(binary.release(env))
}

#[rustler::nif(name = "module_unsafe_deserialize")]
pub fn unsafe_deserialize(binary: Binary) -> NifResult<ModuleResourceResponse> {
    let engine = Engine::default();
    // Safety: This function is inherently unsafe as the provided bytes:
    // 1. Are going to be deserialized directly into Rust objects.
    // 2. Contains the function assembly bodies and, if intercepted, a malicious actor could inject code into executable memory.
    // And as such, the deserialize method is unsafe.
    // However, there isn't much we can do about it here, we will warn users in elixir-land about this, though.
    let module = unsafe {
        Module::deserialize(&engine, binary.as_slice()).map_err(|e| {
            rustler::Error::Term(Box::new(format!("Could not deserialize module: {}", e)))
        })?
    };
    let resource = ResourceArc::new(ModuleResource {
        inner: Mutex::new(module),
    });
    Ok(ModuleResourceResponse {
        ok: atoms::ok(),
        resource,
    })
}
