use rustler::{Encoder, Error, NifResult, Term};
use wit_parser::{FunctionKind, Resolve, TypeDefKind, WorldId, WorldItem, WorldKey};

#[rustler::nif(name = "wit_exported_functions")]
pub fn exported_functions(env: rustler::Env, path: String, wit: String) -> NifResult<Term> {
    let mut resolve = Resolve::new();
    let id = resolve
        .push_str(path, &wit)
        .map_err(|e| rustler::Error::Term(Box::new(format!("Failed to parse WIT: {e}"))))?;
    let world_id = resolve
        .select_world(&[id], None)
        .map_err(|e| rustler::Error::Term(Box::new(format!("Failed to select world: {e}"))))?;
    let exports = &resolve.worlds[world_id].exports;
    let exported_functions = exports
        .iter()
        .filter_map(|(_key, value)| match value {
            WorldItem::Function(function) => Some((&function.name, function.params.len())),
            _ => None,
        })
        .collect::<Vec<(&String, usize)>>();
    Ok(Term::map_from_pairs(env, exported_functions.as_slice()).unwrap())
}

#[rustler::nif(name = "wit_exported_resources")]
pub fn exported_resources<'a>(
    env: rustler::Env<'a>,
    path: String,
    wit: String,
    world: Option<String>,
) -> NifResult<Term<'a>> {
    resources(env, path, wit, world, false)
}

#[rustler::nif(name = "wit_imported_resources")]
pub fn imported_resources<'a>(
    env: rustler::Env<'a>,
    path: String,
    wit: String,
    world: Option<String>,
) -> NifResult<Term<'a>> {
    resources(env, path, wit, world, true)
}

#[rustler::nif(name = "wit_imported_resources_from_path", schedule = "DirtyIo")]
pub fn imported_resources_from_path<'a>(
    env: rustler::Env<'a>,
    path: String,
    world: Option<String>,
) -> NifResult<Term<'a>> {
    let mut resolve = Resolve::new();
    let (package_id, _) = resolve.push_path(&path).map_err(|error| {
        Error::Term(Box::new(format!(
            "Failed to parse WIT path `{path}`: {error}"
        )))
    })?;
    let world_id = resolve
        .select_world(&[package_id], world.as_deref())
        .map_err(|error| Error::Term(Box::new(format!("Failed to select world: {error}"))))?;

    resources_for_world(env, &resolve, world_id, true)
}

fn resources<'a>(
    env: rustler::Env<'a>,
    path: String,
    wit: String,
    world: Option<String>,
    imported: bool,
) -> NifResult<Term<'a>> {
    let mut resolve = Resolve::new();
    let package_id = resolve.push_str(&path, &wit).map_err(|error| {
        Error::Term(Box::new(format!(
            "Failed to parse WIT at `{path}`: {error}"
        )))
    })?;
    let world_id = resolve
        .select_world(&[package_id], world.as_deref())
        .map_err(|error| Error::Term(Box::new(format!("Failed to select world: {error}"))))?;

    resources_for_world(env, &resolve, world_id, imported)
}

fn resources_for_world<'a>(
    env: rustler::Env<'a>,
    resolve: &Resolve,
    world_id: WorldId,
    imported: bool,
) -> NifResult<Term<'a>> {
    let mut resources = Vec::new();

    let world_items = if imported {
        &resolve.worlds[world_id].imports
    } else {
        &resolve.worlds[world_id].exports
    };

    for (world_key, world_item) in world_items {
        let WorldItem::Interface {
            id: interface_id, ..
        } = world_item
        else {
            continue;
        };
        let interface = &resolve.interfaces[*interface_id];
        let interface_name = interface
            .name
            .as_deref()
            .or(match world_key {
                WorldKey::Name(name) => Some(name.as_str()),
                WorldKey::Interface(_) => None,
            })
            .ok_or_else(|| Error::Term(Box::new("A resource interface has no name".to_string())))?;
        let interface_path = interface_world_name(resolve, world_key, *interface_id)?;

        for (resource_name, resource_type_id) in &interface.types {
            if !matches!(resolve.types[*resource_type_id].kind, TypeDefKind::Resource) {
                continue;
            }

            let functions = interface
                .functions
                .values()
                .filter_map(|function| {
                    let (kind, arity, has_return) = match function.kind {
                        FunctionKind::Constructor(id) if id == *resource_type_id => {
                            ("constructor", function.params.len(), true)
                        }
                        FunctionKind::Method(id) if id == *resource_type_id => (
                            "method",
                            function.params.len().saturating_sub(1),
                            function.result.is_some(),
                        ),
                        FunctionKind::AsyncMethod(id) if id == *resource_type_id => (
                            "async-method",
                            function.params.len().saturating_sub(1),
                            function.result.is_some(),
                        ),
                        FunctionKind::Static(id) if id == *resource_type_id => {
                            ("static", function.params.len(), function.result.is_some())
                        }
                        FunctionKind::AsyncStatic(id) if id == *resource_type_id => (
                            "async-static",
                            function.params.len(),
                            function.result.is_some(),
                        ),
                        _ => return None,
                    };
                    Some((
                        function.item_name().to_string(),
                        function.name.clone(),
                        kind.to_string(),
                        arity,
                        has_return,
                    ))
                })
                .collect::<Vec<_>>();

            resources.push(
                (
                    resource_name.clone(),
                    interface_name.to_string(),
                    interface_path.clone(),
                    functions,
                )
                    .encode(env),
            );
        }
    }

    Ok(resources.encode(env))
}

fn interface_world_name(
    resolve: &Resolve,
    world_key: &WorldKey,
    interface_id: wit_parser::InterfaceId,
) -> NifResult<String> {
    if let WorldKey::Name(name) = world_key {
        return Ok(name.clone());
    }

    let interface = &resolve.interfaces[interface_id];
    let interface_name = interface
        .name
        .as_deref()
        .ok_or_else(|| Error::Term(Box::new("A resource interface has no name".to_string())))?;
    let package_id = interface.package.ok_or_else(|| {
        Error::Term(Box::new(format!(
            "Resource interface `{interface_name}` does not belong to a package"
        )))
    })?;
    Ok(resolve.packages[package_id]
        .name
        .interface_id(interface_name))
}
