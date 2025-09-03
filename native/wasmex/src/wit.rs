use rustler::{Atom, Encoder, Env, NifResult, Term};
use wit_parser::{FunctionKind, Resolve, TypeDefKind, WorldItem};

#[rustler::nif(name = "wit_exported_functions")]
pub fn exported_functions(env: rustler::Env, path: String, wit: String) -> NifResult<Term> {
    let mut resolve = Resolve::new();
    let id = resolve
        .push_str(path, &wit)
        .map_err(|e| rustler::Error::Term(Box::new(format!("Failed to parse WIT: {e}"))))?;
    let world_id = resolve
        .select_world(id, None)
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
        .select_world(id, None)
        .map_err(|e| rustler::Error::Term(Box::new(format!("Failed to select world: {e}"))))?;
    
    let mut resources = Vec::new();
    
    // Iterate through exports to find interfaces
    for (name, item) in &resolve.worlds[world_id].exports {
        if let WorldItem::Interface { id: interface_id, .. } = item {
            let interface = &resolve.interfaces[*interface_id];
            
            // Get interface name
            let interface_name = match name {
                wit_parser::WorldKey::Name(s) => s.as_str(),
                wit_parser::WorldKey::Interface(id) => {
                    resolve.interfaces[*id]
                        .name
                        .as_deref()
                        .unwrap_or("unknown")
                }
            };
            
            // Find resources in the interface
            for (type_name, type_id) in &interface.types {
                if let TypeDefKind::Resource = resolve.types[*type_id].kind {
                    let mut methods = Vec::new();
                    
                    // Find all functions related to this resource
                    for (func_name, func) in &interface.functions {
                        match &func.kind {
                            FunctionKind::Constructor(resource_id) if *resource_id == *type_id => {
                                // This is a constructor for our resource
                                let method_info = (
                                    Atom::from_str(env, "constructor").unwrap().encode(env),
                                    func.params.len(),
                                    true, // Constructors always return the resource
                                );
                                methods.push(method_info.encode(env));
                            }
                            FunctionKind::Method(resource_id) | FunctionKind::AsyncMethod(resource_id) 
                                if *resource_id == *type_id => {
                                // This is a method of our resource
                                // Extract just the method name from patterns like "[method]counter.increment"
                                let method_name = if func_name.starts_with("[method]") {
                                    // Remove "[method]resource." prefix
                                    let prefix = format!("[method]{}.", type_name);
                                    if func_name.starts_with(&prefix) {
                                        &func_name[prefix.len()..]
                                    } else {
                                        // Just remove "[method]"
                                        &func_name[8..]
                                    }
                                } else {
                                    func_name.as_str()
                                };
                                
                                // For methods, wit_parser includes the implicit self in params, so subtract 1
                                let arity = if func.params.is_empty() {
                                    0
                                } else {
                                    func.params.len() - 1
                                };
                                
                                let method_info = (
                                    Atom::from_str(env, method_name).unwrap().encode(env),
                                    arity,
                                    func.result.is_some(),
                                );
                                methods.push(method_info.encode(env));
                            }
                            FunctionKind::Static(resource_id) | FunctionKind::AsyncStatic(resource_id) 
                                if *resource_id == *type_id => {
                                // This is a static method of our resource
                                let method_info = (
                                    Atom::from_str(env, func_name).unwrap().encode(env),
                                    func.params.len(),
                                    func.result.is_some(),
                                );
                                methods.push(method_info.encode(env));
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
                        methods.encode(env),
                    );
                    resources.push(resource_info);
                }
            }
        }
    }
    
    Ok(resources.encode(env))
}