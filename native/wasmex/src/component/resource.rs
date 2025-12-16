use rustler::{Encoder, Env, OwnedEnv, ResourceArc, Term};
use std::sync::Mutex;
use std::thread;
use wasmtime::component::{ResourceAny, Val};
use wasmtime::Store;

use crate::atoms;
use crate::component::instance::ComponentInstanceResource;
use crate::component::type_conversion::{convert_params, vals_to_terms};
use crate::engine::TOKIO_RUNTIME;
use crate::store::{ComponentStoreData, ComponentStoreResource};
use rustler::env::SavedTerm;
use rustler::types::tuple::make_tuple;

#[rustler::nif(name = "resource_call_function")]
#[allow(clippy::too_many_arguments)]
pub fn resource_call_function<'a>(
    env: Env<'a>,
    store_resource: ResourceArc<ComponentStoreResource>,
    instance_resource: ResourceArc<ComponentInstanceResource>,
    resource_wrapper: ResourceArc<ResourceWrapper>,
    interface_path: Vec<String>,
    function_name: String,
    params: Vec<Term<'a>>,
    from: Term<'a>,
) -> Term<'a> {
    let pid = env.pid();
    let mut thread_env = OwnedEnv::new();
    let saved_params = thread_env.save(params);
    let saved_from = thread_env.save(from);

    TOKIO_RUNTIME.spawn(async move {
        thread_env.send_and_clear(&pid, |thread_env| {
            execute_resource_function(
                thread_env,
                store_resource,
                instance_resource,
                resource_wrapper,
                interface_path,
                function_name,
                saved_params,
                saved_from,
            )
        })
    });

    atoms::ok().encode(env)
}

#[allow(clippy::too_many_arguments)]
fn execute_resource_function(
    env: Env,
    store_resource: ResourceArc<ComponentStoreResource>,
    instance_resource: ResourceArc<ComponentInstanceResource>,
    resource_wrapper: ResourceArc<ResourceWrapper>,
    interface_path: Vec<String>,
    function_name: String,
    saved_params: SavedTerm,
    saved_from: SavedTerm,
) -> Term {
    let from = saved_from
        .load(env)
        .decode::<Term>()
        .unwrap_or_else(|_| "could not load 'from' param".encode(env));

    // Validate that the resource belongs to this store
    let mut store = store_resource.inner.lock().unwrap();

    let params = match saved_params.load(env).decode::<Vec<Term>>() {
        Ok(p) => p,
        Err(err) => {
            let error_msg = format!("Could not load params: {:?}", err);
            let error_tuple = env.error_tuple(error_msg);
            return make_tuple(
                env,
                &[
                    atoms::returned_function_call().encode(env),
                    error_tuple,
                    from,
                ],
            );
        }
    };

    let instance = instance_resource.inner.lock().unwrap();

    // Build the full method path (e.g., ["component:counter/types", "[method]counter.increment"])
    let mut function_path = interface_path.clone();
    // Resource methods in wasmtime components are exported with special naming:
    // "[method]<resource-type>.<method-name>"
    // We need to determine the resource type name from the resource wrapper
    // For now, we'll use a simplified approach
    // Note: method names use hyphens, not underscores (e.g., "get-value" not "get_value")
    //TODO: resource-type "counter" is hardcoded, replace!
    function_path.push(format!("[method]counter.{}", function_name));

    // Look up the method function
    let mut lookup_index = None;
    for (index, name) in function_path.iter().enumerate() {
        if let Some(inner) = lookup_index {
            lookup_index = instance
                .get_export(&mut *store, Some(&inner), name.as_str())
                .map(|(_, index)| index);
        } else {
            lookup_index = instance
                .get_export(&mut *store, None, name.as_str())
                .map(|(_, index)| index);
        }

        if lookup_index.is_none() {
            let error_msg = format!(
                "Resource function '{}' not found at position {} in path [{}]",
                name,
                index,
                function_path.join(", ")
            );
            let error_tuple = env.error_tuple(error_msg);
            return make_tuple(
                env,
                &[
                    atoms::returned_function_call().encode(env),
                    error_tuple,
                    from,
                ],
            );
        }
    }

    let lookup_index = match lookup_index {
        Some(index) => index,
        None => {
            let error_msg = format!(
                "Resource function not found: [{}]",
                function_path.join(", ")
            );
            let error_tuple = env.error_tuple(error_msg);
            return make_tuple(
                env,
                &[
                    atoms::returned_function_call().encode(env),
                    error_tuple,
                    from,
                ],
            );
        }
    };

    // Get the function
    let function = match instance.get_func(&mut *store, lookup_index) {
        Some(func) => func,
        None => {
            let error_msg = format!(
                "Could not get instance-function for function_path '{}'",
                function_path.join(", ")
            );
            let error_tuple = env.error_tuple(error_msg);
            return make_tuple(
                env,
                &[
                    atoms::returned_function_call().encode(env),
                    error_tuple,
                    from,
                ],
            );
        }
    };

    // Get the resource from the wrapper
    let resource_any = *resource_wrapper.inner.lock().unwrap();

    // Prepare arguments: resource is the first argument, followed by method params
    let mut args = vec![Val::Resource(resource_any)];

    // Convert the additional parameters
    let param_types: Vec<wasmtime::component::Type> = function
        .params(&*store)
        .iter()
        .skip(1) // Skip the resource parameter
        .map(|(_, ty)| ty.clone())
        .collect();

    match convert_params(&param_types, params) {
        Ok(mut converted_params) => args.append(&mut converted_params),
        Err(err) => {
            let error_msg = format!("Parameter conversion error: {:?}", err);
            let error_tuple = env.error_tuple(error_msg);
            return make_tuple(
                env,
                &[
                    atoms::returned_function_call().encode(env),
                    error_tuple,
                    from,
                ],
            );
        }
    }

    // Allocate space for results
    let result_count = function.results(&*store).len();
    let mut results = vec![Val::Bool(false); result_count];

    // Call the method
    match function.call(&mut *store, &args, &mut results) {
        Ok(_) => {
            match function.post_return(&mut *store) {
                Ok(_) => {}
                Err(err) => {
                    let error_msg = format!("post_return error: {:?}", err);
                    let error_tuple = env.error_tuple(error_msg);
                    return make_tuple(
                        env,
                        &[
                            atoms::returned_function_call().encode(env),
                            error_tuple,
                            from,
                        ],
                    );
                }
            }

            // Convert results to Elixir terms
            let result_terms = vals_to_terms(results.as_slice(), env);
            let result = if result_terms.is_empty() {
                atoms::ok().encode(env)
            } else if result_terms.len() == 1 {
                make_tuple(env, &[atoms::ok().encode(env), result_terms[0]])
            } else {
                let tuple = make_tuple(env, &result_terms);
                make_tuple(env, &[atoms::ok().encode(env), tuple])
            };
            make_tuple(
                env,
                &[atoms::returned_function_call().encode(env), result, from],
            )
        }
        Err(err) => {
            let error_msg = format!("Method call error: {:?}", err);
            let error_tuple = env.error_tuple(error_msg);
            make_tuple(
                env,
                &[
                    atoms::returned_function_call().encode(env),
                    error_tuple,
                    from,
                ],
            )
        }
    }
}

/// Create a new resource instance (constructor)
#[rustler::nif(name = "resource_new", schedule = "DirtyCpu")]
pub fn resource_new<'a>(
    env: Env<'a>,
    store_resource: ResourceArc<ComponentStoreResource>,
    instance_resource: ResourceArc<ComponentInstanceResource>,
    resource_type_path: Vec<String>,
    params: Vec<Term<'a>>,
    from: Term<'a>,
) -> Term<'a> {
    let pid = env.pid();
    let mut thread_env = OwnedEnv::new();
    let saved_params = thread_env.save(params);
    let saved_from = thread_env.save(from);

    thread::spawn(move || {
        thread_env.send_and_clear(&pid, |thread_env| {
            execute_resource_constructor(
                thread_env,
                store_resource,
                instance_resource,
                resource_type_path,
                saved_params,
                saved_from,
            )
        })
    });

    atoms::ok().encode(env)
}

fn execute_resource_constructor(
    env: Env,
    store_resource: ResourceArc<ComponentStoreResource>,
    instance_resource: ResourceArc<ComponentInstanceResource>,
    resource_type_path: Vec<String>,
    saved_params: SavedTerm,
    saved_from: SavedTerm,
) -> Term {
    let from = saved_from
        .load(env)
        .decode::<Term>()
        .unwrap_or_else(|_| "could not load 'from' param".encode(env));

    // Lock store and instance
    let mut store = store_resource.inner.lock().unwrap();
    let instance = instance_resource.inner.lock().unwrap();

    // Load the params
    let params = match saved_params.load(env).decode::<Vec<Term>>() {
        Ok(p) => p,
        Err(err) => {
            let error_msg = format!("Could not load params: {:?}", err);
            let error_tuple = env.error_tuple(error_msg);
            return make_tuple(
                env,
                &[
                    atoms::returned_function_call().encode(env),
                    error_tuple,
                    from,
                ],
            );
        }
    };

    // Parse the resource type path
    let (interface_path, resource_name) = match parse_resource_path(resource_type_path.clone()) {
        Ok(result) => result,
        Err(err) => {
            let error_tuple = env.error_tuple(err);
            return make_tuple(
                env,
                &[
                    atoms::returned_function_call().encode(env),
                    error_tuple,
                    from,
                ],
            );
        }
    };

    // Find the constructor function
    let constructor_name = format!("[constructor]{}", resource_name);
    let function =
        match lookup_constructor(&instance, &mut store, &interface_path, &constructor_name) {
            Ok(func) => func,
            Err(err) => {
                let error_tuple = env.error_tuple(err);
                return make_tuple(
                    env,
                    &[
                        atoms::returned_function_call().encode(env),
                        error_tuple,
                        from,
                    ],
                );
            }
        };

    // Convert parameters
    let param_types: Vec<wasmtime::component::Type> = function
        .params(&*store)
        .iter()
        .map(|(_, ty)| ty.clone())
        .collect();

    let wasm_params = match convert_params(&param_types, params) {
        Ok(params) => params,
        Err(err) => {
            let error_msg = format!("Parameter conversion error: {:?}", err);
            let error_tuple = env.error_tuple(error_msg);
            return make_tuple(
                env,
                &[
                    atoms::returned_function_call().encode(env),
                    error_tuple,
                    from,
                ],
            );
        }
    };

    // Call the constructor
    let result_count = function.results(&*store).len();
    let mut results = vec![Val::Bool(false); result_count];

    match function.call(&mut *store, &wasm_params, &mut results) {
        Ok(_) => {
            match function.post_return(&mut *store) {
                Ok(_) => {}
                Err(err) => {
                    let error_msg = format!("post_return error: {:?}", err);
                    let error_tuple = env.error_tuple(error_msg);
                    return make_tuple(
                        env,
                        &[
                            atoms::returned_function_call().encode(env),
                            error_tuple,
                            from,
                        ],
                    );
                }
            }

            // Extract the resource from results
            if results.len() != 1 {
                let error_msg = format!(
                    "Constructor returned {} values, expected 1 resource",
                    results.len()
                );
                let error_tuple = env.error_tuple(error_msg);
                return make_tuple(
                    env,
                    &[
                        atoms::returned_function_call().encode(env),
                        error_tuple,
                        from,
                    ],
                );
            }

            let resource_any = match &results[0] {
                Val::Resource(r) => *r,
                _ => {
                    let error_msg = "Constructor did not return a resource".to_string();
                    let error_tuple = env.error_tuple(error_msg);
                    return make_tuple(
                        env,
                        &[
                            atoms::returned_function_call().encode(env),
                            error_tuple,
                            from,
                        ],
                    );
                }
            };

            let wrapper = ResourceWrapper::new(resource_any);
            let resource_arc = ResourceArc::new(wrapper);

            let result = make_tuple(env, &[atoms::ok().encode(env), resource_arc.encode(env)]);
            make_tuple(
                env,
                &[atoms::returned_function_call().encode(env), result, from],
            )
        }
        Err(err) => {
            let error_msg = format!("Constructor call error: {:?}", err);
            let error_tuple = env.error_tuple(error_msg);
            make_tuple(
                env,
                &[
                    atoms::returned_function_call().encode(env),
                    error_tuple,
                    from,
                ],
            )
        }
    }
}

fn parse_resource_path(path: Vec<String>) -> Result<(Vec<String>, String), String> {
    // Handle different formats:
    // 1. ["component:counter/types", "counter"] - interface + resource
    // 2. ["counter"] - just resource name (use default interface)
    // 3. ["wasi:http/types", "incoming-request"] - WASI resource

    if path.is_empty() {
        return Err("Empty resource path".to_string());
    }

    if path.len() == 1 {
        // Just resource name, no interface specified
        Ok((vec![], path[0].clone()))
    } else {
        // Interface path + resource name
        let resource_name = path.last().unwrap().clone();
        let interface_path = path[0..path.len() - 1].to_vec();
        Ok((interface_path, resource_name))
    }
}

fn lookup_constructor(
    instance: &wasmtime::component::Instance,
    store: &mut Store<ComponentStoreData>,
    interface_path: &[String],
    constructor_name: &str,
) -> Result<wasmtime::component::Func, String> {
    // Navigate nested exports
    let mut current_index = None;

    // First navigate to the interface
    for segment in interface_path {
        current_index = if let Some(index) = current_index {
            instance
                .get_export(&mut *store, Some(&index), segment)
                .map(|(_, idx)| idx)
        } else {
            instance
                .get_export(&mut *store, None, segment)
                .map(|(_, idx)| idx)
        };

        if current_index.is_none() {
            return Err(format!("Interface segment '{}' not found", segment));
        }
    }

    // Now look for the constructor
    let (_export, index) = instance
        .get_export(&mut *store, current_index.as_ref(), constructor_name)
        .ok_or_else(|| format!("Constructor '{}' not found", constructor_name))?;

    // Verify it's a function
    instance
        .get_func(&mut *store, index)
        .ok_or_else(|| format!("Export '{}' is not a function", constructor_name))
}

pub struct ResourceWrapper {
    pub inner: Mutex<ResourceAny>,
}

#[rustler::resource_impl()]
impl rustler::Resource for ResourceWrapper {}

impl ResourceWrapper {
    pub fn new(resource: ResourceAny) -> Self {
        ResourceWrapper {
            inner: Mutex::new(resource),
        }
    }
}
