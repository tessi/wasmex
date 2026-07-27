use std::sync::{Arc, Mutex};

use rustler::env::SavedTerm;
use rustler::types::tuple;
use rustler::{Atom, Encoder, Error, NifResult, OwnedEnv, ResourceArc, Term};
use wasmtime::component::{Func, Instance, ResourceAny, ResourceType, Type, Val};
use wit_parser::{TypeDefKind, WorldItem, WorldKey};

use crate::async_reply::{submit_error, AsyncReply};
use crate::atoms;
use crate::component::ParsedComponent;
use crate::component_instance::ComponentInstanceResource;
use crate::component_type_conversion::{convert_params, val_to_term_with_resource};
use crate::store::{ComponentStoreData, ComponentStoreResource};
use crate::store_executor::{with_deadline, StoreExecutor};

#[derive(Clone)]
struct ResourceMetadata {
    ty: ResourceType,
    interface_path: Vec<String>,
    resource_name: String,
}

struct ResourceContext {
    executor: StoreExecutor<ComponentStoreData>,
    instance: Instance,
    resources: Vec<ResourceMetadata>,
}

struct CallTarget {
    context: Arc<ResourceContext>,
    resource: Option<ResourceArc<ComponentGuestResource>>,
    metadata: ResourceMetadata,
}

/// A guest-owned resource and the component instance required to use it.
pub struct ComponentGuestResource {
    resource: Mutex<Option<ResourceAny>>,
    context: Arc<ResourceContext>,
    metadata: ResourceMetadata,
}

#[rustler::resource_impl()]
impl rustler::Resource for ComponentGuestResource {}

impl ComponentGuestResource {
    fn new(
        resource: ResourceAny,
        context: Arc<ResourceContext>,
        metadata: ResourceMetadata,
    ) -> Self {
        Self {
            resource: Mutex::new(Some(resource)),
            context,
            metadata,
        }
    }

    fn resource(&self) -> Result<ResourceAny, String> {
        self.resource
            .lock()
            .map_err(|error| format!("Could not lock guest resource: {error}"))?
            .as_ref()
            .copied()
            .ok_or_else(|| "Guest resource has already been dropped or moved".to_string())
    }

    pub(crate) fn borrow(&self, expected: ResourceType) -> Result<ResourceAny, String> {
        let resource = self.resource()?;
        ensure_resource_type(resource, expected)?;
        Ok(resource)
    }

    pub(crate) fn owned(&self, expected: ResourceType) -> Result<ResourceAny, String> {
        let value = self.resource()?;
        ensure_resource_type(value, expected)?;
        if !value.owned() {
            return Err("A borrowed guest resource cannot be passed as `own`".to_string());
        }
        Ok(value)
    }

    fn mark_moved(&self, expected: ResourceType) -> Result<(), String> {
        self.owned(expected)?;
        self.resource
            .lock()
            .map_err(|error| format!("Could not lock guest resource: {error}"))?
            .take();
        Ok(())
    }
}

impl Drop for ComponentGuestResource {
    fn drop(&mut self) {
        let resource = self
            .resource
            .lock()
            .ok()
            .and_then(|mut resource| resource.take());
        let Some(resource) = resource else {
            return;
        };

        let _ = self.context.executor.submit(move |mut store| async move {
            let _ = resource.resource_drop_async(&mut store).await;
            store
        });
    }
}

#[rustler::nif(name = "component_guest_resource_new")]
pub fn new(
    store_resource: ResourceArc<ComponentStoreResource>,
    instance_resource: ResourceArc<ComponentInstanceResource>,
    resource_path: Vec<String>,
    params: Term,
    from: Term,
    timeout_ms: Option<u64>,
) -> NifResult<rustler::Atom> {
    let reply = AsyncReply::new(from)?;
    let submit_reply = AsyncReply::new(from)?;
    let executor = store_resource.executor()?;
    let resource_executor = executor.clone();
    let instance = instance_resource.inner;
    let parsed = instance_resource.parsed.clone();
    let (interface_path, resource_name) =
        parse_resource_path(resource_path).map_err(|reason| Error::Term(Box::new(reason)))?;
    let deadline = deadline(timeout_ms);
    let mut thread_env = OwnedEnv::new();
    let saved_params = thread_env.save(params);

    if let Err(error) = executor.submit(move |mut store| async move {
        let interrupt_requested = store.data().interrupt_requested.clone();
        let result = async {
            let context = resource_context(resource_executor, instance, parsed, &mut store)?;
            let resource = execute_constructor(
                &mut thread_env,
                &mut store,
                instance,
                &interface_path,
                &resource_name,
                saved_params,
            )
            .await?;
            let Some(metadata) = metadata_for_type(&context, resource.ty()) else {
                let _ = resource.resource_drop_async(&mut store).await;
                return Err(format!(
                    "Could not identify returned guest resource type `{resource_name}`"
                ));
            };
            Ok::<_, String>(ResourceArc::new(ComponentGuestResource::new(
                resource, context, metadata,
            )))
        };

        if let Some(result) = with_deadline(interrupt_requested, deadline, result).await {
            match result {
                Ok(resource) => reply.send((atoms::ok(), resource)),
                Err(reason) => reply.send_error(reason),
            }
        }
        store
    }) {
        submit_error(submit_reply, error);
    }

    Ok(atoms::ok())
}

async fn execute_constructor(
    thread_env: &mut OwnedEnv,
    store: &mut wasmtime::Store<ComponentStoreData>,
    instance: Instance,
    interface_path: &[String],
    resource_name: &str,
    saved_params: SavedTerm,
) -> Result<ResourceAny, String> {
    let constructor_name = format!("[constructor]{resource_name}");
    let function = lookup_function(instance, store, interface_path, &constructor_name)?;
    let function_type = function.ty(&*store);
    let param_types = function_type
        .params()
        .map(|(_, ty)| ty)
        .collect::<Vec<Type>>();
    let converted_params =
        decode_and_convert_params(thread_env, saved_params, param_types.as_slice(), None)?;
    let result_count = function_type.results().len();

    if result_count != 1 {
        return Err(format!(
            "Guest resource constructor `{constructor_name}` returns {result_count} values; expected one resource"
        ));
    }

    let mut results = vec![Val::Bool(false); result_count];
    function
        .call_async(&mut *store, converted_params.as_slice(), &mut results)
        .await
        .map_err(|error| format!("Error calling guest resource constructor: {error}"))?;

    match results.pop() {
        Some(Val::Resource(resource)) if resource.owned() => Ok(resource),
        Some(Val::Resource(_)) => {
            Err("Guest resource constructor returned a borrowed resource".to_string())
        }
        Some(_) => Err("Guest resource constructor did not return a resource".to_string()),
        None => Err("Guest resource constructor returned no resource".to_string()),
    }
}

#[rustler::nif(name = "component_guest_resource_call")]
pub fn call(
    resource: ResourceArc<ComponentGuestResource>,
    function_kind: String,
    function_name: String,
    params: Term,
    from: Term,
    timeout_ms: Option<u64>,
) -> NifResult<rustler::Atom> {
    let executor = resource.context.executor.clone();
    let target = CallTarget {
        context: resource.context.clone(),
        resource: Some(resource.clone()),
        metadata: resource.metadata.clone(),
    };
    submit_call(
        executor,
        target,
        function_kind,
        function_name,
        params,
        from,
        deadline(timeout_ms),
    )
}

#[allow(clippy::too_many_arguments)]
#[rustler::nif(name = "component_guest_resource_call_static")]
pub fn call_static(
    store_resource: ResourceArc<ComponentStoreResource>,
    instance_resource: ResourceArc<ComponentInstanceResource>,
    resource_path: Vec<String>,
    function_kind: String,
    function_name: String,
    params: Term,
    from: Term,
    timeout_ms: Option<u64>,
) -> NifResult<rustler::Atom> {
    let reply = AsyncReply::new(from)?;
    let submit_reply = AsyncReply::new(from)?;
    let executor = store_resource.executor()?;
    let resource_executor = executor.clone();
    let instance = instance_resource.inner;
    let parsed = instance_resource.parsed.clone();
    let (interface_path, resource_name) =
        parse_resource_path(resource_path).map_err(|reason| Error::Term(Box::new(reason)))?;
    let call_deadline = deadline(timeout_ms);
    let mut thread_env = OwnedEnv::new();
    let saved_params = thread_env.save(params);

    if let Err(error) = executor.submit(move |mut store| async move {
        let interrupt_requested = store.data().interrupt_requested.clone();
        let result = async {
            let context = resource_context(resource_executor, instance, parsed, &mut store)?;
            let metadata = context
                .resources
                .iter()
                .find(|metadata| {
                    metadata.interface_path == interface_path
                        && metadata.resource_name == resource_name
                })
                .cloned()
                .ok_or_else(|| {
                    format!(
                        "Guest resource type `{resource_name}` was not found in `{}`",
                        interface_path.join("/")
                    )
                })?;
            let target = CallTarget {
                context,
                resource: None,
                metadata,
            };
            execute_call(
                &mut thread_env,
                &mut store,
                &target,
                &function_kind,
                &function_name,
                saved_params,
            )
            .await
            .map(|values| (target.context, values))
        };

        if let Some(result) = with_deadline(interrupt_requested, call_deadline, result).await {
            send_call_result(reply, &mut thread_env, result);
        }
        store
    }) {
        submit_error(submit_reply, error);
    }

    Ok(atoms::ok())
}

fn submit_call(
    executor: StoreExecutor<ComponentStoreData>,
    target: CallTarget,
    function_kind: String,
    function_name: String,
    params: Term,
    from: Term,
    call_deadline: Option<tokio::time::Instant>,
) -> NifResult<rustler::Atom> {
    let reply = AsyncReply::new(from)?;
    let submit_reply = AsyncReply::new(from)?;
    let mut thread_env = OwnedEnv::new();
    let saved_params = thread_env.save(params);

    if let Err(error) = executor.submit(move |mut store| async move {
        let interrupt_requested = store.data().interrupt_requested.clone();
        let result = execute_call(
            &mut thread_env,
            &mut store,
            &target,
            &function_kind,
            &function_name,
            saved_params,
        );
        let result = with_deadline(interrupt_requested, call_deadline, result).await;

        if let Some(result) = result {
            send_call_result(
                reply,
                &mut thread_env,
                result.map(|values| (target.context, values)),
            );
        }
        store
    }) {
        submit_error(submit_reply, error);
    }

    Ok(atoms::ok())
}

async fn execute_call(
    thread_env: &mut OwnedEnv,
    store: &mut wasmtime::Store<ComponentStoreData>,
    target: &CallTarget,
    function_kind: &str,
    function_name: &str,
    saved_params: SavedTerm,
) -> Result<Vec<Val>, String> {
    let (export_prefix, include_resource) = match function_kind {
        "method" | "async-method" => ("method", true),
        "static" | "async-static" => ("static", false),
        kind => return Err(format!("Unsupported guest resource function kind `{kind}`")),
    };
    let resource = target.resource.as_deref();
    if include_resource && resource.is_none() {
        return Err("Guest resource methods require a resource handle".to_string());
    }

    let export_name = format!(
        "[{export_prefix}]{}.{function_name}",
        target.metadata.resource_name
    );
    let function = lookup_function(
        target.context.instance,
        store,
        &target.metadata.interface_path,
        &export_name,
    )?;
    let function_type = function.ty(&*store);
    let param_types = function_type
        .params()
        .skip(usize::from(include_resource))
        .map(|(_, ty)| ty)
        .collect::<Vec<Type>>();
    let mut converted_params =
        decode_and_convert_params(thread_env, saved_params, param_types.as_slice(), resource)?;

    if let Some(resource) = resource {
        converted_params.insert(0, Val::Resource(resource.resource()?));
    }

    let mut results = vec![Val::Bool(false); function_type.results().len()];
    function
        .call_async(&mut *store, converted_params.as_slice(), &mut results)
        .await
        .map_err(|error| {
            format!("Error calling guest resource function `{function_name}`: {error}")
        })?;
    if let Err(reason) = validate_result_resources(&results, &target.context) {
        drop_result_resources(store, &results).await;
        return Err(reason);
    }
    Ok(results)
}

fn send_call_result(
    reply: AsyncReply,
    thread_env: &mut OwnedEnv,
    result: Result<(Arc<ResourceContext>, Vec<Val>), String>,
) {
    let result = match result {
        Ok((context, values)) => thread_env.run(|env| encode_call_result(env, values, &context)),
        Err(reason) => thread_env.run(|env| env.error_tuple(reason).encode(env)),
    };
    let saved = thread_env.save(result);
    reply.send_saved(std::mem::replace(thread_env, OwnedEnv::new()), saved);
}

fn validate_result_resources(values: &[Val], context: &Arc<ResourceContext>) -> Result<(), String> {
    for value in values {
        match value {
            Val::Resource(resource) => {
                if !resource.owned() {
                    return Err("A borrowed guest resource cannot escape a call".to_string());
                }
                if metadata_for_type(context, resource.ty()).is_none() {
                    return Err("Could not identify a returned guest resource type".to_string());
                }
            }
            Val::List(values) | Val::Tuple(values) => {
                validate_result_resources(values, context)?;
            }
            Val::Record(fields) => {
                for (_, value) in fields {
                    validate_result_resources(std::slice::from_ref(value), context)?;
                }
            }
            Val::Option(Some(value)) => {
                validate_result_resources(std::slice::from_ref(value), context)?;
            }
            Val::Result(Ok(Some(value))) | Val::Result(Err(Some(value))) => {
                validate_result_resources(std::slice::from_ref(value), context)?;
            }
            Val::Variant(_, Some(value)) => {
                validate_result_resources(std::slice::from_ref(value), context)?;
            }
            _ => {}
        }
    }
    Ok(())
}

async fn drop_result_resources(store: &mut wasmtime::Store<ComponentStoreData>, values: &[Val]) {
    let mut resources = Vec::new();
    collect_result_resources(values, &mut resources);
    for resource in resources {
        let _ = resource.resource_drop_async(&mut *store).await;
    }
}

fn collect_result_resources(values: &[Val], resources: &mut Vec<ResourceAny>) {
    for value in values {
        match value {
            Val::Resource(resource) => resources.push(*resource),
            Val::List(values) | Val::Tuple(values) => {
                collect_result_resources(values, resources);
            }
            Val::Record(fields) => {
                for (_, value) in fields {
                    collect_result_resources(std::slice::from_ref(value), resources);
                }
            }
            Val::Option(Some(value)) => {
                collect_result_resources(std::slice::from_ref(value), resources);
            }
            Val::Result(Ok(Some(value))) | Val::Result(Err(Some(value))) => {
                collect_result_resources(std::slice::from_ref(value), resources);
            }
            Val::Variant(_, Some(value)) => {
                collect_result_resources(std::slice::from_ref(value), resources);
            }
            _ => {}
        }
    }
}

#[rustler::nif(name = "component_guest_resource_drop")]
pub fn drop_resource(
    resource: ResourceArc<ComponentGuestResource>,
    from: Term,
    timeout_ms: Option<u64>,
) -> NifResult<rustler::Atom> {
    let reply = AsyncReply::new(from)?;
    let submit_reply = AsyncReply::new(from)?;
    let executor = resource.context.executor.clone();
    let drop_deadline = deadline(timeout_ms);

    if let Err(error) = executor.submit(move |mut store| async move {
        let resource_to_drop = resource
            .resource
            .lock()
            .map_err(|error| format!("Could not lock guest resource: {error}"))
            .map(|mut resource| resource.take());

        match resource_to_drop {
            Ok(None) => reply.send(atoms::ok()),
            Err(reason) => reply.send_error(reason),
            Ok(Some(resource)) => {
                let interrupt_requested = store.data().interrupt_requested.clone();
                let result = with_deadline(
                    interrupt_requested,
                    drop_deadline,
                    resource.resource_drop_async(&mut store),
                )
                .await;
                if let Some(result) = result {
                    match result {
                        Ok(()) => reply.send(atoms::ok()),
                        Err(error) => {
                            reply.send_error(format!("Could not drop guest resource: {error}"))
                        }
                    }
                }
            }
        }
        store
    }) {
        submit_error(submit_reply, error);
    }

    Ok(atoms::ok())
}

fn resource_context(
    executor: StoreExecutor<ComponentStoreData>,
    instance: Instance,
    parsed: Arc<ParsedComponent>,
    store: &mut wasmtime::Store<ComponentStoreData>,
) -> Result<Arc<ResourceContext>, String> {
    let resources = discover_resources(instance, store, &parsed)?;
    Ok(Arc::new(ResourceContext {
        executor,
        instance,
        resources,
    }))
}

fn discover_resources(
    instance: Instance,
    store: &mut wasmtime::Store<ComponentStoreData>,
    parsed: &ParsedComponent,
) -> Result<Vec<ResourceMetadata>, String> {
    let mut resources = Vec::new();
    let world = &parsed.resolve.worlds[parsed.world_id];

    for (world_key, world_item) in &world.exports {
        let WorldItem::Interface {
            id: interface_id, ..
        } = world_item
        else {
            continue;
        };
        let interface = &parsed.resolve.interfaces[*interface_id];
        let interface_export = interface_export_name(&parsed.resolve, world_key, *interface_id)?;
        let (_, interface_index) = instance
            .get_export(&mut *store, None, &interface_export)
            .ok_or_else(|| format!("Export path segment `{interface_export}` was not found"))?;

        for (resource_name, type_id) in &interface.types {
            if !matches!(parsed.resolve.types[*type_id].kind, TypeDefKind::Resource) {
                continue;
            }
            let (_, resource_index) = instance
                .get_export(&mut *store, Some(&interface_index), resource_name)
                .ok_or_else(|| {
                    format!(
                        "Guest resource type `{resource_name}` was not found in `{interface_export}`"
                    )
                })?;
            let ty = instance
                .get_resource(&mut *store, resource_index)
                .ok_or_else(|| {
                    format!(
                        "Guest resource export `{resource_name}` in `{interface_export}` is not a resource type"
                    )
                })?;
            resources.push(ResourceMetadata {
                ty,
                interface_path: vec![interface_export.clone()],
                resource_name: resource_name.clone(),
            });
        }
    }
    Ok(resources)
}

fn interface_export_name(
    resolve: &wit_parser::Resolve,
    world_key: &WorldKey,
    interface_id: wit_parser::InterfaceId,
) -> Result<String, String> {
    if let WorldKey::Name(name) = world_key {
        return Ok(name.clone());
    }

    let interface = &resolve.interfaces[interface_id];
    let interface_name = interface
        .name
        .as_deref()
        .ok_or_else(|| "An exported resource interface has no name".to_string())?;
    let package_id = interface.package.ok_or_else(|| {
        format!("Exported interface `{interface_name}` does not belong to a package")
    })?;
    Ok(resolve.packages[package_id]
        .name
        .interface_id(interface_name))
}

fn metadata_for_type(
    context: &Arc<ResourceContext>,
    resource_type: ResourceType,
) -> Option<ResourceMetadata> {
    context
        .resources
        .iter()
        .find(|metadata| metadata.ty == resource_type)
        .cloned()
}

fn ensure_resource_type(resource: ResourceAny, expected: ResourceType) -> Result<(), String> {
    if resource.ty() == expected {
        Ok(())
    } else {
        Err("Guest resource argument has the wrong resource type".to_string())
    }
}

fn parse_resource_path(path: Vec<String>) -> Result<(Vec<String>, String), String> {
    let Some((resource_name, interface_path)) = path.split_last() else {
        return Err("Guest resource path cannot be empty".to_string());
    };
    if interface_path.is_empty() {
        return Err(
            "Guest resource path must contain an exported interface and a resource name"
                .to_string(),
        );
    }
    Ok((interface_path.to_vec(), resource_name.clone()))
}

fn lookup_function(
    instance: Instance,
    store: &mut wasmtime::Store<ComponentStoreData>,
    interface_path: &[String],
    function_name: &str,
) -> Result<Func, String> {
    let mut current_index = None;
    for segment in interface_path {
        current_index = instance
            .get_export(&mut *store, current_index.as_ref(), segment)
            .map(|(_, index)| index);
        if current_index.is_none() {
            return Err(format!("Export path segment `{segment}` was not found"));
        }
    }

    let (_, function_index) = instance
        .get_export(&mut *store, current_index.as_ref(), function_name)
        .ok_or_else(|| {
            format!(
                "Guest resource function `{function_name}` was not found in `{}`",
                interface_path.join("/")
            )
        })?;
    instance
        .get_func(&mut *store, function_index)
        .ok_or_else(|| format!("Guest resource export `{function_name}` is not a function"))
}

fn decode_and_convert_params(
    thread_env: &mut OwnedEnv,
    saved_params: SavedTerm,
    param_types: &[Type],
    protected_resource: Option<&ComponentGuestResource>,
) -> Result<Vec<Val>, String> {
    thread_env.run(|env| {
        let params = saved_params
            .load(env)
            .decode::<Vec<Term>>()
            .map_err(|error| format!("Could not decode guest resource parameters: {error:?}"))?;
        if params.len() != param_types.len() {
            return Err(format!(
                "Expected {} guest resource arguments, got {}",
                param_types.len(),
                params.len()
            ));
        }
        let converted = convert_params(param_types, params.clone()).map_err(|error| {
            let reason = match error {
                Error::Term(value) => value
                    .encode(env)
                    .decode::<String>()
                    .unwrap_or_else(|_| "invalid value".to_string()),
                error => format!("{error:?}"),
            };
            format!("Could not convert guest resource arguments: {reason}")
        })?;
        consume_owned_resources(param_types, &params, protected_resource)?;
        Ok(converted)
    })
}

fn consume_owned_resources(
    param_types: &[Type],
    params: &[Term],
    protected_resource: Option<&ComponentGuestResource>,
) -> Result<(), String> {
    let mut resources = Vec::new();
    for (param_type, param) in param_types.iter().zip(params) {
        collect_owned_resources(param_type, param, &mut resources)?;
    }

    let mut addresses = std::collections::HashSet::new();
    let protected_address =
        protected_resource.map(|resource| std::ptr::from_ref(resource) as usize);
    for (resource, expected) in &resources {
        let address = std::ptr::from_ref::<ComponentGuestResource>(resource) as usize;
        if protected_address == Some(address) {
            return Err("A guest resource method cannot move its own receiver".to_string());
        }
        if !addresses.insert(address) {
            return Err("The same guest resource cannot be moved more than once".to_string());
        }
        resource.owned(*expected)?;
    }
    for (resource, expected) in resources {
        resource.mark_moved(expected)?;
    }
    Ok(())
}

fn collect_owned_resources<'a>(
    param_type: &Type,
    param: &Term<'a>,
    resources: &mut Vec<(ResourceArc<ComponentGuestResource>, ResourceType)>,
) -> Result<(), String> {
    match param_type {
        Type::Own(resource_type) => {
            resources.push((decode_resource(param)?, *resource_type));
        }
        Type::List(list_type) => {
            for value in param
                .decode::<Vec<Term>>()
                .map_err(|error| format!("Could not decode resource list: {error:?}"))?
            {
                collect_owned_resources(&list_type.ty(), &value, resources)?;
            }
        }
        Type::Tuple(tuple_type) => {
            let values = tuple::get_tuple(*param)
                .map_err(|error| format!("Could not decode resource tuple: {error:?}"))?;
            for (value_type, value) in tuple_type.types().zip(values) {
                collect_owned_resources(&value_type, &value, resources)?;
            }
        }
        Type::Record(record_type) => {
            let fields = param
                .decode::<std::collections::HashMap<Term, Term>>()
                .map_err(|error| format!("Could not decode resource record: {error:?}"))?;
            for field in record_type.fields() {
                if let Some((_, value)) = fields.iter().find(|(key, _)| {
                    crate::component_type_conversion::term_to_field_name(key) == field.name
                }) {
                    collect_owned_resources(&field.ty, value, resources)?;
                }
            }
        }
        Type::Option(option_type) if param.get_type() == rustler::TermType::Tuple => {
            let values = tuple::get_tuple(*param)
                .map_err(|error| format!("Could not decode resource option: {error:?}"))?;
            if let Some(value) = values.get(1) {
                collect_owned_resources(&option_type.ty(), value, resources)?;
            }
        }
        Type::Result(result_type) if param.get_type() == rustler::TermType::Tuple => {
            let values = tuple::get_tuple(*param)
                .map_err(|error| format!("Could not decode resource result: {error:?}"))?;
            if let (Some(kind), Some(value)) = (values.first(), values.get(1)) {
                let kind = kind
                    .atom_to_string()
                    .map_err(|error| format!("Could not decode resource result: {error:?}"))?;
                let value_type = if kind == "ok" {
                    result_type.ok()
                } else {
                    result_type.err()
                };
                if let Some(value_type) = value_type {
                    collect_owned_resources(&value_type, value, resources)?;
                }
            }
        }
        Type::Variant(variant_type) if param.get_type() == rustler::TermType::Tuple => {
            let values = tuple::get_tuple(*param)
                .map_err(|error| format!("Could not decode resource variant: {error:?}"))?;
            if let (Some(case), Some(value)) = (values.first(), values.get(1)) {
                let case = case
                    .atom_to_string()
                    .map_err(|error| format!("Could not decode resource variant: {error:?}"))?;
                if let Some(value_type) = variant_type
                    .cases()
                    .find(|variant_case| variant_case.name == case)
                    .and_then(|variant_case| variant_case.ty)
                {
                    collect_owned_resources(&value_type, value, resources)?;
                }
            }
        }
        _ => {}
    }
    Ok(())
}

fn decode_resource(term: &Term) -> Result<ResourceArc<ComponentGuestResource>, String> {
    let resource_key = Atom::from_str(term.get_env(), "resource")
        .map_err(|error| format!("Could not decode guest resource: {error:?}"))?;
    term.map_get(resource_key)
        .and_then(Term::decode)
        .map_err(|error| format!("Could not decode guest resource: {error:?}"))
}

fn encode_call_result<'a>(
    env: rustler::Env<'a>,
    values: Vec<Val>,
    context: &Arc<ResourceContext>,
) -> Term<'a> {
    let terms = values
        .iter()
        .map(|value| {
            val_to_term_with_resource(value, env, vec![], &|resource, env| {
                let metadata = metadata_for_type(context, resource.ty())
                    .expect("all exported guest resource types are discovered");
                encode_resource(
                    env,
                    ResourceArc::new(ComponentGuestResource::new(
                        resource,
                        context.clone(),
                        metadata,
                    )),
                )
            })
        })
        .collect::<Vec<_>>();

    match terms.as_slice() {
        [] => atoms::ok().encode(env),
        [value] => (atoms::ok(), *value).encode(env),
        _ => (atoms::ok(), terms).encode(env),
    }
}

fn encode_resource<'a>(
    env: rustler::Env<'a>,
    resource: ResourceArc<ComponentGuestResource>,
) -> Term<'a> {
    let resource_key = Atom::from_str(env, "resource").expect("resource is a valid atom");
    let reference_key = Atom::from_str(env, "reference").expect("reference is a valid atom");
    rustler::types::elixir_struct::make_ex_struct(env, "Elixir.Wasmex.Components.GuestResource")
        .expect("GuestResource is a valid Elixir module")
        .map_put(resource_key, resource.encode(env))
        .expect("GuestResource.resource can be encoded")
        .map_put(reference_key, env.make_ref().encode(env))
        .expect("GuestResource.reference can be encoded")
}

fn deadline(timeout_ms: Option<u64>) -> Option<tokio::time::Instant> {
    timeout_ms
        .map(|timeout| tokio::time::Instant::now() + std::time::Duration::from_millis(timeout))
}
