use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use rustler::env::SavedTerm;
use wit_parser::{Function, Resolve, WorldItem};

use crate::async_reply::{submit_error, AsyncReply};
use crate::atoms;
use crate::component::{ComponentResource, ParsedComponent};
use crate::store::ComponentStoreData;
use crate::store::ComponentStoreResource;
use rustler::NifResult;
use rustler::ResourceArc;
use rustler::{Encoder, OwnedEnv};
use rustler::{Error, LocalPid};
use wasmtime::component::{Instance, Linker, LinkerInstance, Type, Val};
use wasmtime::{Error as WasmtimeError, Trap};

use rustler::Term;

use wasmtime_wasi;
use wasmtime_wasi_http;

use crate::component_type_conversion::{
    convert_params, convert_result_term, encode_result, vals_to_terms,
};

type ComponentCallbackSender = tokio::sync::oneshot::Sender<(bool, Vec<Val>)>;

pub struct ComponentCallbackToken {
    pub name: String,
    pub namespace: Option<String>,
    pub return_sender: Mutex<Option<ComponentCallbackSender>>,
}

pub struct ComponentCallbackTokenResource {
    pub token: ComponentCallbackToken,
}

#[rustler::resource_impl()]
impl rustler::Resource for ComponentCallbackTokenResource {}

pub struct ComponentInstanceResource {
    pub inner: Instance,
    pub parsed: Arc<ParsedComponent>,
}

#[rustler::resource_impl()]
impl rustler::Resource for ComponentInstanceResource {}

#[rustler::nif(name = "component_instance_new")]
pub fn new_instance(
    store_resource: ResourceArc<ComponentStoreResource>,
    component_resource: ResourceArc<ComponentResource>,
    imports: Term,
    from: Term,
) -> NifResult<rustler::Atom> {
    let component = component_resource
        .inner
        .lock()
        .map_err(|e| {
            rustler::Error::Term(Box::new(format!(
                "Could not unlock component resource as the mutex was poisoned: {e}"
            )))
        })?
        .clone();
    let callback_pid = imports.get_env().pid();
    let parsed = component_resource.parsed.clone();
    let term_env = OwnedEnv::new();
    let imports = term_env.save(imports);
    let executor = store_resource.executor()?;
    let reply = AsyncReply::new(from)?;
    let submit_reply = AsyncReply::new(from)?;

    if let Err(error) = executor.submit(move |mut store| async move {
        let linker = term_env
            .run(|env| {
                let imports = imports.load(env);
                create_linker(&store, imports, callback_pid)
            })
            .map_err(|error| format!("{error:?}"));

        let result = match linker {
            Ok(linker) => linker
                .instantiate_async(&mut store, &component)
                .await
                .map(|instance| {
                    ResourceArc::new(ComponentInstanceResource {
                        inner: instance,
                        parsed,
                    })
                })
                .map_err(|error| error.to_string()),
            Err(error) => Err(error),
        };

        match result {
            Ok(instance) => reply.send(instance),
            Err(error) => reply.send_error(error),
        }
        store
    }) {
        submit_error(submit_reply, error);
    }

    Ok(atoms::ok())
}

fn create_linker(
    store: &wasmtime::Store<ComponentStoreData>,
    imports: Term,
    callback_pid: LocalPid,
) -> NifResult<Linker<ComponentStoreData>> {
    let mut linker = Linker::new(store.engine());
    linker.allow_shadowing(true);
    wasmtime_wasi::p2::add_to_linker_async(&mut linker)
        .map_err(|error| Error::Term(Box::new(error.to_string())))?;
    if store.data().http.is_some() {
        wasmtime_wasi_http::p2::add_only_http_to_linker_async(&mut linker)
            .map_err(|error| Error::Term(Box::new(error.to_string())))?;
    }

    let imports_map = imports.decode::<HashMap<String, Term>>()?;
    for (name, implementation) in imports_map {
        if Term::is_tuple(implementation) {
            link_import(&mut linker.root(), name, None, callback_pid)?;
        } else {
            let imports_map = implementation.decode::<HashMap<String, Term>>()?;
            let mut namespace = linker
                .instance(&name)
                .map_err(|error| Error::Term(Box::new(error.to_string())))?;
            for implementation_name in imports_map.into_keys() {
                link_import(
                    &mut namespace,
                    implementation_name,
                    Some(name.clone()),
                    callback_pid,
                )?;
            }
        }
    }
    Ok(linker)
}

fn create_callback_token(
    name: String,
    namespace: Option<String>,
    return_sender: tokio::sync::oneshot::Sender<(bool, Vec<Val>)>,
) -> ResourceArc<ComponentCallbackTokenResource> {
    ResourceArc::new(ComponentCallbackTokenResource {
        token: ComponentCallbackToken {
            name,
            namespace,
            return_sender: Mutex::new(Some(return_sender)),
        },
    })
}

async fn call_elixir_import(
    name: String,
    namespace: Option<String>,
    params: &[Val],
    result_values: &mut [Val],
    pid: LocalPid,
) -> Result<(), WasmtimeError> {
    let mut msg_env = OwnedEnv::new();
    let (return_sender, return_receiver) = tokio::sync::oneshot::channel();
    let callback_token = create_callback_token(name.clone(), namespace.clone(), return_sender);

    let _ = msg_env.send_and_clear(&pid, |env| {
        let param_terms = vals_to_terms(params, env);
        (
            atoms::invoke_callback(),
            namespace,
            name,
            callback_token.clone(),
            param_terms,
        )
    });

    let (success, returned_values) = return_receiver
        .await
        .map_err(|_| WasmtimeError::msg("Component callback result channel closed"))?;
    if !success {
        return Err(WasmtimeError::msg("Callback failed"));
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
    pid: LocalPid,
) -> NifResult<()> {
    let name_for_closure = name.clone();

    linker_instance
        .func_new_async(
            &name,
            move |_store, _function_type, params, result_values| {
                Box::new(call_elixir_import(
                    name_for_closure.clone(),
                    namespace.clone(),
                    params,
                    result_values,
                    pid,
                ))
            },
        )
        .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))
}

#[rustler::nif(name = "component_call_function")]
pub fn call_exported_function(
    component_store_resource: ResourceArc<ComponentStoreResource>,
    instance_resource: ResourceArc<ComponentInstanceResource>,
    function_name_path: Vec<String>,
    given_params: Term,
    from: Term,
    timeout_ms: Option<u64>,
) -> NifResult<rustler::Atom> {
    let reply = AsyncReply::new(from)?;
    let executor = component_store_resource.executor()?;
    let instance = instance_resource.inner;
    let mut thread_env = OwnedEnv::new();
    let function_params = thread_env.save(given_params);
    let submit_reply = AsyncReply::new(from)?;
    let deadline = timeout_ms
        .map(|timeout| tokio::time::Instant::now() + std::time::Duration::from_millis(timeout));

    if let Err(error) = executor.submit(move |mut store| async move {
        if deadline.is_some_and(|deadline| tokio::time::Instant::now() >= deadline) {
            return store;
        }
        let result = component_execute_function(
            &mut thread_env,
            &mut store,
            instance,
            function_name_path,
            function_params,
        )
        .await;
        if deadline.is_none_or(|deadline| tokio::time::Instant::now() < deadline) {
            reply.send_saved(thread_env, result);
        }
        store
    }) {
        submit_error(submit_reply, error);
    }

    Ok(atoms::ok())
}

async fn component_execute_function(
    thread_env: &mut OwnedEnv,
    component_store: &mut wasmtime::Store<ComponentStoreData>,
    instance: Instance,
    function_name_path: Vec<String>,
    function_params: SavedTerm,
) -> SavedTerm {
    let prepared = thread_env.run(|env| {
        let given_params = function_params
            .load(env)
            .decode::<Vec<Term>>()
            .map_err(|error| format!("could not load 'function params': {error:?}"))?;

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
                let reason = if function_name_path.len() == 1 {
                    format!(
                        "exported function `{}` not found.",
                        function_name_path.join(", ")
                    )
                } else {
                    format!(
                        "exported function `[{}]` not found. Could not find `{}` at position {}",
                        function_name_path.join(", "),
                        name,
                        index
                    )
                };
                return Err(reason);
            }
        }

        let lookup_index = lookup_index.ok_or_else(|| {
            format!(
                "exported function `{}` not found.",
                function_name_path.join(", ")
            )
        })?;

        let function = instance
            .get_func(&mut *component_store, lookup_index)
            .ok_or_else(|| {
                format!(
                    "exported function `{}` not found",
                    function_name_path.join(", ")
                )
            })?;

        let function_type = function.ty(&*component_store);
        let param_types = function_type.params();
        let param_types = param_types.map(|x| x.1.clone()).collect::<Vec<Type>>();

        let converted_params =
            convert_params(param_types.as_ref(), given_params).map_err(|error| match error {
                Error::Term(value) => {
                    let value = value.encode(env);
                    value
                        .decode::<String>()
                        .unwrap_or_else(|_| format!("Error converting param: {value:?}"))
                }
                error => format!("Error converting param: {error:?}"),
            })?;
        let results_count = function_type.results().len();
        Ok::<_, String>((function, converted_params, results_count))
    });

    let (function, converted_params, results_count) = match prepared {
        Ok(prepared) => prepared,
        Err(reason) => {
            let result = thread_env.run(|env| env.error_tuple(reason).encode(env));
            return thread_env.save(result);
        }
    };

    let mut result_values = vec![Val::Bool(false); results_count];
    let call_result = function
        .call_async(
            &mut *component_store,
            converted_params.as_slice(),
            &mut result_values,
        )
        .await;

    let result = thread_env.run(|env| {
        match call_result {
            Ok(()) => encode_result(env, result_values),
            Err(err) => {
                let reason = format!("{err}");
                if let Ok(trap) = err.downcast::<Trap>() {
                    env.error_tuple(format!(
                        "Error during function excecution ({trap}): {reason}"
                    ))
                } else {
                    env.error_tuple(format!("Error during function excecution: {reason}"))
                }
            }
        }
        .encode(env)
    });
    thread_env.save(result)
}

#[rustler::nif(name = "component_receive_callback_result")]
pub fn receive_callback_result(
    component_resource: ResourceArc<ComponentResource>,
    token_resource: ResourceArc<ComponentCallbackTokenResource>,
    success: bool,
    result: Term,
) -> NifResult<rustler::Atom> {
    if !success {
        send_component_callback_result(&token_resource, false, vec![])?;
        return Ok(atoms::ok());
    }

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

    let return_values =
        match convert_return_values(&component_resource.parsed.resolve, import_function, result) {
            Ok(values) => values,
            Err(_) => {
                send_component_callback_result(&token_resource, false, vec![])?;
                return Ok(atoms::ok());
            }
        };
    send_component_callback_result(&token_resource, true, return_values)?;

    Ok(atoms::ok())
}

fn convert_return_values(
    wit_resolver: &Resolve,
    function: &Function,
    result: Term,
) -> Result<Vec<Val>, String> {
    if let Some(result_type) = &function.result {
        Ok(vec![convert_result_term(
            result,
            result_type,
            wit_resolver,
            vec![],
        )
        .map_err(|(msg, path)| {
            if path.is_empty() {
                msg
            } else {
                format!("{msg:?} at path: {path:?}")
            }
        })?])
    } else {
        Ok(vec![])
    }
}

fn send_component_callback_result(
    token_resource: &ComponentCallbackTokenResource,
    success: bool,
    values: Vec<Val>,
) -> NifResult<()> {
    let sender = token_resource
        .token
        .return_sender
        .lock()
        .map_err(|error| {
            Error::Term(Box::new(format!(
                "Failed to lock component callback sender: {error}"
            )))
        })?
        .take()
        .ok_or_else(|| Error::Term(Box::new("Component callback result was already sent")))?;
    let _ = sender.send((success, values));
    Ok(())
}
