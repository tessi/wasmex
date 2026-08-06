use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use rustler::env::SavedTerm;
use rustler::types::tuple;

use crate::async_reply::{submit_error, AsyncReply};
use crate::atoms;
use crate::component::{ComponentResource, ParsedComponent};
use crate::component_host_resource::HostResourceRegistry;
use crate::store::ComponentStoreData;
use crate::store::ComponentStoreResource;
use rustler::NifResult;
use rustler::ResourceArc;
use rustler::{Encoder, OwnedEnv};
use rustler::{Error, LocalPid};
use wasmtime::component::{types::ComponentFunc, Instance, Linker, LinkerInstance, Type, Val};
use wasmtime::{Error as WasmtimeError, Trap};

use rustler::Term;

use wasmtime_wasi;
use wasmtime_wasi_http;

use crate::component_type_conversion::{convert_params, encode_result};

struct ComponentCallbackResult {
    success: bool,
    env: OwnedEnv,
    result: SavedTerm,
}

type ComponentCallbackSender = tokio::sync::oneshot::Sender<ComponentCallbackResult>;

pub struct ComponentCallbackToken {
    return_sender: Mutex<Option<ComponentCallbackSender>>,
}

pub struct ComponentCallbackTokenResource {
    pub token: ComponentCallbackToken,
}

#[rustler::resource_impl()]
impl rustler::Resource for ComponentCallbackTokenResource {}

pub struct ComponentInstanceResource {
    pub inner: Instance,
    pub parsed: Arc<ParsedComponent>,
    _host_resources: Arc<HostResourceRegistry>,
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
            Ok((linker, host_resources)) => linker
                .instantiate_async(&mut store, &component)
                .await
                .map(|instance| {
                    ResourceArc::new(ComponentInstanceResource {
                        inner: instance,
                        parsed,
                        _host_resources: host_resources,
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
) -> NifResult<(Linker<ComponentStoreData>, Arc<HostResourceRegistry>)> {
    let mut linker = Linker::new(store.engine());
    let host_resources = Arc::new(HostResourceRegistry::new());
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
            link_implementation(
                &mut linker.root(),
                name,
                implementation,
                None,
                callback_pid,
                host_resources.clone(),
            )?;
        } else {
            let imports_map = implementation.decode::<HashMap<String, Term>>()?;
            let mut namespace = linker
                .instance(&name)
                .map_err(|error| Error::Term(Box::new(error.to_string())))?;
            for (implementation_name, implementation) in imports_map {
                link_implementation(
                    &mut namespace,
                    implementation_name,
                    implementation,
                    Some(name.clone()),
                    callback_pid,
                    host_resources.clone(),
                )?;
            }
        }
    }
    Ok((linker, host_resources))
}

fn link_implementation(
    linker_instance: &mut LinkerInstance<ComponentStoreData>,
    name: String,
    implementation: Term,
    namespace: Option<String>,
    callback_pid: LocalPid,
    host_resources: Arc<HostResourceRegistry>,
) -> NifResult<()> {
    match implementation_tag(implementation).as_deref() {
        Some("fn") => link_import(
            linker_instance,
            name,
            namespace,
            callback_pid,
            host_resources,
        ),
        Some("resource") => link_resource(
            linker_instance,
            name,
            namespace,
            callback_pid,
            host_resources,
        ),
        _ => Ok(()),
    }
}

fn implementation_tag(term: Term) -> Option<String> {
    tuple::get_tuple(term).ok()?.first()?.atom_to_string().ok()
}

fn create_callback_token(
    return_sender: ComponentCallbackSender,
) -> ResourceArc<ComponentCallbackTokenResource> {
    ResourceArc::new(ComponentCallbackTokenResource {
        token: ComponentCallbackToken {
            return_sender: Mutex::new(Some(return_sender)),
        },
    })
}

#[allow(clippy::too_many_arguments)]
async fn call_elixir_import(
    mut store: wasmtime::StoreContextMut<'_, ComponentStoreData>,
    function_type: ComponentFunc,
    name: String,
    namespace: Option<String>,
    params: &[Val],
    result_values: &mut [Val],
    pid: LocalPid,
    host_resources: Arc<HostResourceRegistry>,
) -> Result<(), WasmtimeError> {
    let params_env = OwnedEnv::new();
    let saved_params = params_env.run(|env| {
        host_resources
            .vals_to_terms(params, env, &mut store)
            .map(|terms| params_env.save(terms))
    });
    let saved_params = saved_params.map_err(WasmtimeError::msg)?;
    let mut msg_env = OwnedEnv::new();
    let (return_sender, return_receiver) = tokio::sync::oneshot::channel();
    let callback_token = create_callback_token(return_sender);

    msg_env
        .send_and_clear(&pid, |env| {
            let param_terms =
                params_env.run(|params_env| saved_params.load(params_env).in_env(env));
            (
                atoms::invoke_callback(),
                namespace,
                name,
                callback_token,
                param_terms,
            )
        })
        .map_err(|_| WasmtimeError::msg("Could not send component callback"))?;

    let callback_result = return_receiver
        .await
        .map_err(|_| WasmtimeError::msg("Component callback result channel closed"))?;
    if !callback_result.success {
        return Err(WasmtimeError::msg("Callback failed"));
    }

    let result_types = function_type.results().collect::<Vec<_>>();
    if result_types.len() != result_values.len() {
        return Err(WasmtimeError::msg(format!(
            "Expected {} component callback results, got {} result slots",
            result_types.len(),
            result_values.len()
        )));
    }
    if result_types.len() > 1 {
        return Err(WasmtimeError::msg(
            "Component callbacks with multiple results are not supported",
        ));
    }
    if let Some(result_type) = result_types.first() {
        let converted = callback_result.env.run(|env| {
            let result = callback_result.result.load(env);
            host_resources
                .term_to_val(&result, result_type, &mut store)
                .map_err(|error| format!("{error:?}"))
        });
        let converted = converted.map_err(WasmtimeError::msg)?;
        result_values[0] = converted;
    }
    Ok(())
}

fn link_import(
    linker_instance: &mut LinkerInstance<ComponentStoreData>,
    name: String,
    namespace: Option<String>,
    pid: LocalPid,
    host_resources: Arc<HostResourceRegistry>,
) -> NifResult<()> {
    let name_for_closure = name.clone();

    linker_instance
        .func_new_async(&name, move |store, function_type, params, result_values| {
            Box::new(call_elixir_import(
                store,
                function_type,
                name_for_closure.clone(),
                namespace.clone(),
                params,
                result_values,
                pid,
                host_resources.clone(),
            ))
        })
        .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))
}

fn link_resource(
    linker_instance: &mut LinkerInstance<ComponentStoreData>,
    name: String,
    namespace: Option<String>,
    pid: LocalPid,
    host_resources: Arc<HostResourceRegistry>,
) -> NifResult<()> {
    let (_, resource_type) = host_resources
        .register_type()
        .map_err(|reason| Error::Term(Box::new(reason)))?;
    linker_instance
        .resource_async(&name.clone(), resource_type, move |_store, rep| {
            let name = name.clone();
            let namespace = namespace.clone();
            let host_resources = host_resources.clone();
            Box::new(async move {
                call_elixir_resource_destructor(host_resources, rep, pid, namespace, name).await
            })
        })
        .map_err(|error| Error::Term(Box::new(error.to_string())))
}

async fn call_elixir_resource_destructor(
    host_resources: Arc<HostResourceRegistry>,
    rep: u32,
    pid: LocalPid,
    namespace: Option<String>,
    name: String,
) -> Result<(), WasmtimeError> {
    let resource = host_resources.take_term(rep).map_err(WasmtimeError::msg)?;
    let mut msg_env = OwnedEnv::new();
    let (return_sender, return_receiver) = tokio::sync::oneshot::channel();
    let callback_token = create_callback_token(return_sender);

    msg_env
        .send_and_clear(&pid, |env| {
            (
                atoms::invoke_callback(),
                namespace,
                name,
                callback_token,
                vec![resource.copy_to(env)],
            )
        })
        .map_err(|_| WasmtimeError::msg("Could not send component destructor callback"))?;
    let result = return_receiver
        .await
        .map_err(|_| WasmtimeError::msg("Component destructor callback result channel closed"))?;
    if result.success {
        Ok(())
    } else {
        Err(WasmtimeError::msg("Component destructor callback failed"))
    }
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
    token_resource: ResourceArc<ComponentCallbackTokenResource>,
    success: bool,
    result: Term,
) -> NifResult<rustler::Atom> {
    let env = OwnedEnv::new();
    let result = env.save(result);
    send_component_callback_result(
        &token_resource,
        ComponentCallbackResult {
            success,
            env,
            result,
        },
    )?;

    Ok(atoms::ok())
}

fn send_component_callback_result(
    token_resource: &ComponentCallbackTokenResource,
    result: ComponentCallbackResult,
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
    let _ = sender.send(result);
    Ok(())
}
