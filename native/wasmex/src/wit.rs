use rustler::{Atom, Encoder, Env, NifResult, Term};
use wit_parser::{FunctionKind, Resolve, TypeDefKind, WorldItem};

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
pub fn exported_resources<'a>(env: Env<'a>, path: String, wit: String) -> NifResult<Term<'a>> {
    let mut resolve = Resolve::new();
    let id = resolve
        .push_str(path, &wit)
        .map_err(|e| rustler::Error::Term(Box::new(format!("Failed to parse WIT: {e}"))))?;
    let world_id = resolve
        .select_world(&[id], None)
        .map_err(|e| rustler::Error::Term(Box::new(format!("Failed to select world: {e}"))))?;

    let mut resources = Vec::new();

    // Iterate through exports to find interfaces
    for (name, item) in &resolve.worlds[world_id].exports {
        if let WorldItem::Interface {
            id: interface_id, ..
        } = item
        {
            let interface = &resolve.interfaces[*interface_id];

            let interface_name = match name {
                wit_parser::WorldKey::Name(s) => s.as_str(),
                wit_parser::WorldKey::Interface(id) => {
                    resolve.interfaces[*id].name.as_deref().unwrap_or("unknown")
                }
            };

            // Find resources in the interface
            for (type_name, type_id) in &interface.types {
                if let TypeDefKind::Resource = resolve.types[*type_id].kind {
                    let mut functions = Vec::new();

                    // Find all functions related to this resource
                    for (func_name, func) in &interface.functions {
                        match &func.kind {
                            FunctionKind::Constructor(resource_id) if *resource_id == *type_id => {
                                let function_info = (
                                    Atom::from_str(env, "constructor").unwrap().encode(env),
                                    func.params.len(),
                                    true, // Constructors always return the resource
                                );
                                functions.push(function_info.encode(env));
                            }
                            FunctionKind::Method(resource_id)
                            | FunctionKind::AsyncMethod(resource_id)
                                if *resource_id == *type_id =>
                            {
                                let function_name = func_name
                                    .strip_prefix(&format!("[method]{}.", type_name))
                                    .unwrap_or_else(|| {
                                        func_name.strip_prefix("[method]").unwrap_or(func_name)
                                    });

                                let function_info = (
                                    Atom::from_str(env, function_name).unwrap().encode(env),
                                    func.params.len(),
                                    func.result.is_some(),
                                );
                                functions.push(function_info.encode(env));
                            }
                            FunctionKind::Static(resource_id)
                            | FunctionKind::AsyncStatic(resource_id)
                                if *resource_id == *type_id =>
                            {
                                let function_info = (
                                    Atom::from_str(env, func_name).unwrap().encode(env),
                                    func.params.len(),
                                    func.result.is_some(),
                                );
                                functions.push(function_info.encode(env));
                            }
                            _ => {
                                // Not related to this resource
                            }
                        }
                    }

                    // Create resource info tuple
                    let resource_info = (
                        Atom::from_str(env, type_name).unwrap().encode(env),
                        Atom::from_str(env, interface_name).unwrap().encode(env),
                        functions.encode(env),
                    );
                    resources.push(resource_info);
                }
            }
        }
    }

    Ok(resources.encode(env))
}
