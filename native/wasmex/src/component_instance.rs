use std::collections::HashMap;
use std::sync::{Condvar, Mutex};

use rustler::env::SavedTerm;
use wit_parser::{Function, Resolve, WorldItem};

use std::thread;

use crate::atoms;
use crate::component::ComponentResource;
use crate::store::ComponentStoreData;
use crate::store::ComponentStoreResource;
use rustler::types::tuple::make_tuple;
use rustler::NifResult;
use rustler::ResourceArc;
use rustler::{Encoder, OwnedEnv};
use rustler::{Error, LocalPid};
use wasmtime::component::{Instance, Linker, LinkerInstance, Type, Val};
use wasmtime::Trap;
use wiggle::anyhow::{self};

use rustler::Term;

use wasmtime::Store;

use wasmtime_wasi;
use wasmtime_wasi_http;

use crate::component_type_conversion::{
    convert_params, convert_result_term, encode_result_with_store, vals_to_terms_with_store,
};

pub struct ComponentCallbackToken {
    pub continue_signal: Condvar,
    pub name: String,
    pub namespace: Option<String>,
    pub return_values: Mutex<Option<(bool, Vec<Val>)>>,
}

pub struct ComponentCallbackTokenResource {
    pub token: ComponentCallbackToken,
}

#[rustler::resource_impl()]
impl rustler::Resource for ComponentCallbackTokenResource {}

pub struct ComponentInstanceResource {
    pub inner: Mutex<Instance>,
}

#[rustler::resource_impl()]
impl rustler::Resource for ComponentInstanceResource {}

#[rustler::nif(name = "component_instance_new")]
pub fn new_instance(
    store_resource: ResourceArc<ComponentStoreResource>,
    component_resource: ResourceArc<ComponentResource>,
    imports: rustler::Term,
) -> NifResult<ResourceArc<ComponentInstanceResource>> {
    let store: &mut Store<ComponentStoreData> =
        &mut *(store_resource.inner.lock().map_err(|e| {
            rustler::Error::Term(Box::new(format!(
                "Could not unlock store resource as the mutex was poisoned: {e}"
            )))
        })?);

    let component = component_resource.inner.lock().map_err(|e| {
        rustler::Error::Term(Box::new(format!(
            "Could not unlock component resource as the mutex was poisoned: {e}"
        )))
    })?;

    let mut linker = Linker::new(store.engine());
    linker.allow_shadowing(true);

    // Add core WASI P2 interfaces (includes filesystem, sockets, clocks, random, io, cli)
    wasmtime_wasi::p2::add_to_linker_sync(&mut linker).map_err(|e| {
        rustler::Error::Term(Box::new(format!(
            "Failed to add WASI P2 interfaces to linker: {}",
            e
        )))
    })?;

    // Add HTTP support if enabled
    if store.data().http.is_some() {
        wasmtime_wasi_http::add_only_http_to_linker_sync(&mut linker).map_err(|e| {
            rustler::Error::Term(Box::new(format!(
                "Failed to add WASI HTTP interfaces to linker: {}",
                e
            )))
        })?;
    }

    // Instantiate the component

    // Handle imports
    let imports_map = imports.decode::<HashMap<String, Term>>()?;
    for (name, implementation) in imports_map {
        if Term::is_tuple(implementation) {
            // root imports
            link_import(&mut linker.root(), name, None, implementation)?;
        } else {
            let imports_map = implementation.decode::<HashMap<String, Term>>()?;
            let mut namespace = linker
                .instance(&name)
                .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))?;
            for (implementation_name, implementation) in imports_map {
                link_import(
                    &mut namespace,
                    implementation_name,
                    Some(name.clone()),
                    implementation,
                )?;
            }
        }
    }

    let instance = linker
        .instantiate(&mut *store, &component)
        .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))?;

    Ok(ResourceArc::new(ComponentInstanceResource {
        inner: Mutex::new(instance),
    }))
}

fn create_callback_token(
    name: String,
    namespace: Option<String>,
) -> ResourceArc<ComponentCallbackTokenResource> {
    ResourceArc::new(ComponentCallbackTokenResource {
        token: ComponentCallbackToken {
            continue_signal: Condvar::new(),
            name,
            namespace,
            return_values: Mutex::new(None),
        },
    })
}

fn call_elixir_import(
    name: String,
    namespace: Option<String>,
    params: &[Val],
    result_values: &mut [Val],
    pid: LocalPid,
) -> Result<(), anyhow::Error> {
    let mut msg_env = OwnedEnv::new();
    let callback_token = create_callback_token(name.clone(), namespace.clone());

    let _ = msg_env.send_and_clear(&pid, |env| {
        // TODO: Get store_id from context - using 0 for now
        let param_terms = vals_to_terms_with_store(params, env, 0);
        (
            atoms::invoke_callback(),
            namespace,
            name,
            callback_token.clone(),
            param_terms,
        )
    });

    let mut result = callback_token.token.return_values.lock().unwrap();
    while result.is_none() {
        result = callback_token.token.continue_signal.wait(result).unwrap();
    }

    let (success, returned_values) = result.take().unwrap();
    if !success {
        return Err(anyhow::anyhow!("Callback failed"));
    }

    if !returned_values.is_empty() {
        result_values[0] = returned_values[0].clone();
    }
    Ok(())
}

fn link_import(
    linker_instance: &mut LinkerInstance<ComponentStoreData>,
    name: String,
    namespace: Option<String>,
    implementation: Term,
) -> NifResult<()> {
    let pid = implementation.get_env().pid();
    let name_for_closure = name.clone();

    linker_instance
        .func_new(&name, move |_store, params, result_values| {
            call_elixir_import(
                name_for_closure.clone(),
                namespace.clone(),
                params,
                result_values,
                pid,
            )
        })
        .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))
}

#[rustler::nif(name = "component_call_function", schedule = "DirtyCpu")]
pub fn call_exported_function(
    env: rustler::Env,
    component_store_resource: ResourceArc<ComponentStoreResource>,
    instance_resource: ResourceArc<ComponentInstanceResource>,
    function_name_path: Vec<String>,
    given_params: Term,
    from: Term,
) -> rustler::Atom {
    let pid = env.pid();
    // create erlang environment for the thread
    let mut thread_env = OwnedEnv::new();
    // copy over params into the thread environment
    let function_params = thread_env.save(given_params);
    let from = thread_env.save(from);

    thread::spawn(move || {
        thread_env.send_and_clear(&pid, |thread_env| {
            component_execute_function(
                thread_env,
                component_store_resource,
                instance_resource,
                function_name_path,
                function_params,
                from,
            )
        })
    });

    atoms::ok()
}

fn component_execute_function(
    thread_env: rustler::Env,
    component_store_resource: ResourceArc<ComponentStoreResource>,
    instance_resource: ResourceArc<ComponentInstanceResource>,
    function_name_path: Vec<String>,
    function_params: SavedTerm,
    from: SavedTerm,
) -> Term {
    let component_store: &mut Store<ComponentStoreData> =
        &mut (component_store_resource.inner.lock().unwrap());
    let instance = &mut instance_resource.inner.lock().unwrap();

    let from = from
        .load(thread_env)
        .decode::<Term>()
        .unwrap_or_else(|_| "could not load 'from' param".encode(thread_env));
    let given_params = match function_params.load(thread_env).decode::<Vec<Term>>() {
        Ok(vec) => vec,
        Err(err) => {
            return make_error_tuple(
                &thread_env,
                format!("could not load 'function params': {err:?}"),
                from,
            )
        }
    };

    // reduce function_name_path to a lookup index by iterating over function_name_path and calling instance.get_export
    let mut lookup_index = None;
    for (index, name) in function_name_path.iter().enumerate() {
        if let Some(inner) = lookup_index {
            lookup_index = instance
                .get_export(&mut *component_store, Some(&inner), name.as_str())
                .map(|(_, index)| index);
        } else {
            lookup_index = instance
                .get_export(&mut *component_store, None, name.as_str())
                .map(|(_, index)| index);
        }

        if lookup_index.is_none() {
            if function_name_path.len() == 1 {
                return make_error_tuple(
                    &thread_env,
                    format!(
                        "exported function `{}` not found.",
                        function_name_path.join(", ")
                    ),
                    from,
                );
            } else {
                return make_error_tuple(
                    &thread_env,
                    format!(
                        "exported function `[{}]` not found. Could not find `{}` at position {}",
                        function_name_path.join(", "),
                        name,
                        index
                    ),
                    from,
                );
            }
        }
    }

    let lookup_index = match lookup_index {
        Some(index) => index,
        None => {
            return make_error_tuple(
                &thread_env,
                format!(
                    "exported function `{}` not found.",
                    function_name_path.join(", ")
                ),
                from,
            );
        }
    };

    let function_result = instance.get_func(&mut *component_store, lookup_index);
    let function = match function_result {
        Some(func) => func,
        None => {
            return make_error_tuple(
                &thread_env,
                format!(
                    "exported function `{}` not found",
                    function_name_path.join(", ")
                ),
                from,
            )
        }
    };

    let param_types = function.params(&mut *component_store);
    let param_types = param_types
        .as_ref()
        .iter()
        .map(|x| x.1.clone())
        .collect::<Vec<Type>>();

    let converted_params = match convert_params(param_types.as_ref(), given_params) {
        Ok(params) => params,
        Err(Error::Term(e)) => {
            return make_error_tuple(&thread_env, e.encode(thread_env), from);
        }
        Err(e) => {
            let reason = format!("Error converting param: {e:?}");
            return make_error_tuple(&thread_env, &reason, from);
        }
    };
    let results_count = function.results(&*component_store).len();

    let mut result = vec![Val::Bool(false); results_count];
    match function.call(
        &mut *component_store,
        converted_params.as_slice(),
        &mut result,
    ) {
        Ok(_) => {
            let _ = function.post_return(&mut *component_store);
            let store_id = component_store.data().store_id;
            encode_result_with_store(&thread_env, result, from, store_id)
        }
        Err(err) => {
            let reason = format!("{err}");
            if let Ok(trap) = err.downcast::<Trap>() {
                make_raise_tuple(
                    &thread_env,
                    format!("Error during function excecution ({trap}): {reason}"),
                    from,
                )
            } else {
                make_raise_tuple(
                    &thread_env,
                    format!("Error during function excecution: {reason}"),
                    from,
                )
            }
        }
    }
}

fn make_error_tuple<'a>(env: &rustler::Env<'a>, reason: impl Encoder, from: Term<'a>) -> Term<'a> {
    make_tuple(
        *env,
        &[
            atoms::returned_function_call().encode(*env),
            env.error_tuple(reason),
            from,
        ],
    )
}

fn make_raise_tuple<'a>(env: &rustler::Env<'a>, reason: impl Encoder, from: Term<'a>) -> Term<'a> {
    make_tuple(
        *env,
        &[
            atoms::returned_function_call().encode(*env),
            make_tuple(*env, &[atoms::raise().encode(*env), reason.encode(*env)]),
            from,
        ],
    )
}

#[rustler::nif(name = "component_receive_callback_result")]
pub fn receive_callback_result(
    component_resource: ResourceArc<ComponentResource>,
    token_resource: ResourceArc<ComponentCallbackTokenResource>,
    _success: bool,
    result: Term,
) -> NifResult<rustler::Atom> {
    let parsed_component = &component_resource.parsed;
    let world = &parsed_component.resolve.worlds[parsed_component.world_id];
    let name = &token_resource.token.name;
    let namespace = &token_resource.token.namespace;

    let import_function = if let Some(namespace) = namespace {
        let (_package_name, _interface_name, interface_id) = parsed_component
            .resolve
            .package_names
            .iter()
            .flat_map(|(package_name, package_id)| {
                let package = parsed_component.resolve.packages.get(*package_id).unwrap();
                package
                    .interfaces
                    .iter()
                    .map(|(interface_name, interface_id)| {
                        (package_name.clone(), interface_name.clone(), *interface_id)
                    })
            })
            .find(|(package_name, interface_name, _interface_id)| {
                let namespace = namespace.to_string();
                let full_name = package_name.interface_id(interface_name);
                full_name == namespace
            })
            .ok_or_else(|| {
                Error::Term(Box::new(format!("Could not find package name {namespace}")))
            })?;
        let interface = parsed_component
            .resolve
            .interfaces
            .get(interface_id)
            .unwrap();
        let (_function_name, function) = interface
            .functions
            .iter()
            .find(|(function_name, _function)| function_name.as_str() == name)
            .ok_or_else(|| {
                Error::Term(Box::new(format!("Could not find import function {name}")))
            })?;
        function
    } else {
        world
            .imports
            .iter()
            .filter_map(|(_, item)| match item {
                WorldItem::Function(function) => Some(function),
                _ => None,
            })
            .find(|f| f.item_name() == name)
            .ok_or_else(|| {
                Error::Term(Box::new(format!("Could not find import function {name}")))
            })?
    };

    let return_values = token_resource
        .token
        .return_values
        .lock()
        .map_err(|e| Error::Term(Box::new(format!("Failed to lock return values: {e}"))))?;

    convert_return_values(
        &component_resource.parsed.resolve,
        import_function,
        return_values,
        result,
    )
    .map_err(|e| {
        Error::Term(Box::new(format!(
            "Failed to convert imported function return values - {e}"
        )))
    })?;

    token_resource.token.continue_signal.notify_one();

    Ok(atoms::ok())
}

fn convert_return_values(
    wit_resolver: &Resolve,
    function: &Function,
    mut return_values: std::sync::MutexGuard<'_, Option<(bool, Vec<Val>)>>,
    result: Term,
) -> Result<(), String> {
    if let Some(result_type) = &function.result {
        let mut vals = Vec::new();
        vals.push(
            convert_result_term(result, result_type, wit_resolver, vec![]).map_err(
                |(msg, path)| {
                    if path.is_empty() {
                        msg
                    } else {
                        format!("{msg:?} at path: {path:?}")
                    }
                },
            )?,
        );

        // Set the return values
        *return_values = Some((true, vals));
    } else {
        *return_values = Some((true, vec![]));
    }

    Ok(())
}
