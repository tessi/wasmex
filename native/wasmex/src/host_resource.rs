use rustler::{Encoder, Env, Error, NifResult, ResourceArc, Term};
use std::collections::HashMap;
use std::sync::{Arc, Mutex, RwLock};
use wasmtime::component::{Resource, ResourceAny, ResourceType as WasmResourceType, Val};
use wasmtime::Store;

use crate::atoms;
use crate::store::{ComponentStoreData, ComponentStoreResource};
use crate::wasi_resource::{ResourceType, WasiResourceWrapper};

// Global registry for host resource types
lazy_static::lazy_static! {
    static ref HOST_RESOURCE_TYPES: RwLock<HashMap<String, Arc<WasmResourceType>>> = RwLock::new(HashMap::new());
    static ref HOST_RESOURCE_INSTANCES: RwLock<HashMap<u64, HostResourceInstance>> = RwLock::new(HashMap::new());
}

/// Represents a host-defined resource instance
#[derive(Debug, Clone)]
pub struct HostResourceInstance {
    /// Unique ID for this resource instance
    pub resource_id: u64,
    /// The WIT type name (e.g., "database-connection")
    pub type_name: String,
    /// Store ID this resource belongs to
    pub store_id: usize,
    /// Internal representation for wasmtime
    pub rep: u32,
}

/// Phantom type for host resources
#[derive(Debug, Clone)]
pub struct HostResource {
    pub type_name: String,
}

impl HostResourceInstance {
    pub fn new(resource_id: u64, type_name: String, store_id: usize, rep: u32) -> Self {
        HostResourceInstance {
            resource_id,
            type_name,
            store_id,
            rep,
        }
    }
}

/// Register a host resource type with wasmtime
#[rustler::nif(name = "host_resource_type_register")]
pub fn host_resource_type_register(type_name: String) -> NifResult<rustler::Atom> {
    // Create a new host resource type
    let resource_type = WasmResourceType::host::<HostResource>();

    // Store it in our global registry
    let mut types = HOST_RESOURCE_TYPES.write().map_err(|e| {
        Error::Term(Box::new(format!(
            "Could not lock host resource types: {}",
            e
        )))
    })?;

    types.insert(type_name.clone(), Arc::new(resource_type));

    Ok(atoms::ok())
}

/// NIF to create a new host resource instance
#[rustler::nif(name = "host_resource_new")]
pub fn host_resource_new(
    store_resource: ResourceArc<ComponentStoreResource>,
    resource_id: u64,
    type_name: String,
) -> NifResult<ResourceArc<WasiResourceWrapper>> {
    let mut store = store_resource
        .inner
        .lock()
        .map_err(|e| Error::Term(Box::new(format!("Could not lock store: {}", e))))?;

    let store_id = store.data().store_id;

    // Get the resource type from our registry
    let types = HOST_RESOURCE_TYPES.read().map_err(|e| {
        Error::Term(Box::new(format!(
            "Could not lock host resource types: {}",
            e
        )))
    })?;

    let _resource_type = types.get(&type_name).ok_or_else(|| {
        Error::Term(Box::new(format!(
            "Host resource type '{}' not registered. Call host_resource_type_register first.",
            type_name
        )))
    })?;

    // Create a unique representation for this resource instance
    // In a real system, this would be managed by a resource table
    let rep = resource_id as u32; // Simple mapping for now

    // Create the host resource instance
    let host_instance = HostResourceInstance::new(resource_id, type_name.clone(), store_id, rep);

    // Store the instance in our global registry
    let mut instances = HOST_RESOURCE_INSTANCES.write().map_err(|e| {
        Error::Term(Box::new(format!(
            "Could not lock host resource instances: {}",
            e
        )))
    })?;

    instances.insert(resource_id, host_instance.clone());

    // Create a ResourceAny that wraps our host resource
    let resource_any = create_host_resource_any(host_instance, &mut store)?;

    // Wrap it in our WasiResourceWrapper
    let wrapper = WasiResourceWrapper {
        inner: Mutex::new(resource_any),
        resource_type: ResourceType::HostDefined {
            type_name: type_name.clone(),
        },
        is_owned: true,
        store_id,
    };

    Ok(ResourceArc::new(wrapper))
}

/// Creates a ResourceAny for a host resource
fn create_host_resource_any(
    host_instance: HostResourceInstance,
    store: &mut Store<ComponentStoreData>,
) -> NifResult<ResourceAny> {
    // Create an owned Resource with our representation
    let resource = Resource::<HostResource>::new_own(host_instance.rep);

    // Convert to ResourceAny
    let resource_any = resource.try_into_resource_any(store).map_err(|e| {
        Error::Term(Box::new(format!(
            "Failed to convert resource to ResourceAny: {}",
            e
        )))
    })?;

    Ok(resource_any)
}

/// Dispatch a method call from WASM to a host resource in Elixir
///
/// This function is called by wasmtime when a WASM component invokes a method
/// on a host-defined resource. It bridges the call to Elixir code.
///
/// ## Current Limitation
///
/// This implementation currently sends a message to the Elixir process but does not
/// wait for a response. It returns a placeholder value (true) immediately.
///
/// A proper implementation would require one of these approaches:
/// 1. **Threaded NIF**: Use a separate OS thread to block waiting for the response
/// 2. **Async/await pattern**: Redesign the interface to be asynchronous
/// 3. **Message queue**: Implement a message queue with timeout handling
///
/// The synchronous nature of wasmtime's resource method calls makes this challenging
/// in the NIF environment where blocking is not allowed.
pub fn dispatch_host_method(
    env: Env,
    resource_rep: u32,
    method_name: String,
    params: Vec<Val>,
    pid: rustler::LocalPid,
) -> NifResult<Val> {
    // Find the resource instance by its representation
    let instances = HOST_RESOURCE_INSTANCES.read().map_err(|e| {
        Error::Term(Box::new(format!(
            "Could not lock host resource instances: {}",
            e
        )))
    })?;

    // Find resource by rep (simple lookup for now)
    let resource_instance = instances
        .values()
        .find(|inst| inst.rep == resource_rep)
        .ok_or_else(|| {
            Error::Term(Box::new(format!(
                "Host resource with rep {} not found",
                resource_rep
            )))
        })?;

    let resource_id = resource_instance.resource_id;
    let type_name = resource_instance.type_name.clone();

    // Convert wasmtime Val parameters to Elixir terms
    let elixir_params = convert_vals_to_terms(env, params)?;

    // Create a message to send to the Elixir process
    // This will be handled by the ResourceManager
    let msg = rustler::types::tuple::make_tuple(
        env,
        &[
            atoms::host_resource_call().encode(env),
            resource_id.encode(env),
            type_name.encode(env),
            method_name.encode(env),
            elixir_params.encode(env),
        ],
    );

    // Send message to the Elixir process
    let _ = env.send(&pid, msg);

    // TODO: Implement synchronous response handling
    // This requires architectural changes to handle the blocking nature of
    // wasmtime resource method calls within the NIF environment.
    // For now, return a placeholder value.
    Ok(Val::Bool(true))
}

/// Convert wasmtime Val values to Elixir terms
fn convert_vals_to_terms(env: Env, vals: Vec<Val>) -> NifResult<Vec<Term>> {
    vals.into_iter().map(|val| val_to_term(env, val)).collect()
}

/// Convert a single wasmtime Val to an Elixir term
fn val_to_term(env: Env, val: Val) -> NifResult<Term> {
    match val {
        Val::Bool(b) => Ok(b.encode(env)),
        Val::S8(i) => Ok(i.encode(env)),
        Val::U8(i) => Ok(i.encode(env)),
        Val::S16(i) => Ok(i.encode(env)),
        Val::U16(i) => Ok(i.encode(env)),
        Val::S32(i) => Ok(i.encode(env)),
        Val::U32(i) => Ok(i.encode(env)),
        Val::S64(i) => Ok(i.encode(env)),
        Val::U64(i) => Ok(i.encode(env)),
        Val::Float32(f) => Ok(f.encode(env)),
        Val::Float64(f) => Ok(f.encode(env)),
        Val::String(s) => Ok(s.encode(env)),
        Val::List(list) => {
            let terms: NifResult<Vec<Term>> =
                list.iter().map(|v| val_to_term(env, v.clone())).collect();
            Ok(terms?.encode(env))
        }
        Val::Record(fields) => {
            // Create a map from the fields
            let mut map = rustler::types::map::map_new(env);
            for (field_name, field_val) in fields.iter() {
                let value = val_to_term(env, field_val.clone())?;
                map = map.map_put(field_name.encode(env), value).unwrap();
            }
            Ok(map.encode(env))
        }
        Val::Option(opt) => match opt {
            Some(v) => {
                let inner = val_to_term(env, *v)?;
                Ok(rustler::types::tuple::make_tuple(
                    env,
                    &[atoms::some().encode(env), inner],
                ))
            }
            None => Ok(atoms::none().encode(env)),
        },
        Val::Result(res) => match res {
            Ok(Some(v)) => {
                let inner = val_to_term(env, *v)?;
                Ok(rustler::types::tuple::make_tuple(
                    env,
                    &[atoms::ok().encode(env), inner],
                ))
            }
            Ok(None) => Ok(rustler::types::tuple::make_tuple(
                env,
                &[atoms::ok().encode(env), atoms::nil().encode(env)],
            )),
            Err(Some(v)) => {
                let inner = val_to_term(env, *v)?;
                Ok(rustler::types::tuple::make_tuple(
                    env,
                    &[atoms::error().encode(env), inner],
                ))
            }
            Err(None) => Ok(rustler::types::tuple::make_tuple(
                env,
                &[atoms::error().encode(env), atoms::nil().encode(env)],
            )),
        },
        _ => Err(Error::Term(Box::new(format!(
            "Unsupported Val type: {:?}",
            val
        )))),
    }
}

/// Convert an Elixir term back to a wasmtime Val
pub fn convert_term_to_val<'a>(term: Term<'a>) -> NifResult<Val> {
    // Check for basic types first
    if let Ok(b) = term.decode::<bool>() {
        return Ok(Val::Bool(b));
    }
    if let Ok(i) = term.decode::<i32>() {
        return Ok(Val::S32(i));
    }
    if let Ok(i) = term.decode::<i64>() {
        return Ok(Val::S64(i));
    }
    if let Ok(u) = term.decode::<u32>() {
        return Ok(Val::U32(u));
    }
    if let Ok(u) = term.decode::<u64>() {
        return Ok(Val::U64(u));
    }
    if let Ok(f) = term.decode::<f32>() {
        return Ok(Val::Float32(f));
    }
    if let Ok(f) = term.decode::<f64>() {
        return Ok(Val::Float64(f));
    }
    if let Ok(s) = term.decode::<String>() {
        return Ok(Val::String(s));
    }

    // Check for list
    if let Ok(list) = term.decode::<Vec<Term>>() {
        let vals: NifResult<Vec<Val>> = list.into_iter().map(|t| convert_term_to_val(t)).collect();
        return Ok(Val::List(vals?));
    }

    // Check for Option (represented as :none or {:some, value})
    if term.is_atom() {
        if let Ok(atom) = term.decode::<rustler::Atom>() {
            if atom == atoms::none() {
                return Ok(Val::Option(None));
            }
        }
    }

    if let Ok((tag, value)) = term.decode::<(rustler::Atom, Term)>() {
        if tag == atoms::some() {
            let inner = convert_term_to_val(value)?;
            return Ok(Val::Option(Some(Box::new(inner))));
        }
        if tag == atoms::ok() {
            let inner = convert_term_to_val(value)?;
            return Ok(Val::Result(Ok(Some(Box::new(inner)))));
        }
        if tag == atoms::error() {
            let inner = convert_term_to_val(value)?;
            return Ok(Val::Result(Err(Some(Box::new(inner)))));
        }
    }

    // Check for map (records)
    if let Ok(map) = term.decode::<std::collections::HashMap<String, Term>>() {
        let mut fields = Vec::new();
        for (key, val) in map {
            fields.push((key, convert_term_to_val(val)?));
        }
        return Ok(Val::Record(fields));
    }

    Err(Error::Term(Box::new(
        "Cannot convert Elixir term to Val: unsupported type".to_string(),
    )))
}

/// Handle dropping a host resource
pub fn drop_host_resource(resource_id: u64) -> NifResult<()> {
    // Remove from our registry
    let mut instances = HOST_RESOURCE_INSTANCES.write().map_err(|e| {
        Error::Term(Box::new(format!(
            "Could not lock host resource instances: {}",
            e
        )))
    })?;

    instances.remove(&resource_id);

    // Successfully dropped host resource
    Ok(())
}

/// NIF to call a method on a host resource from Elixir
/// This is used when Elixir code wants to invoke methods on host resources
#[rustler::nif(name = "host_resource_call_method", schedule = "DirtyCpu")]
pub fn host_resource_call_method<'a>(
    env: Env<'a>,
    store_resource: ResourceArc<ComponentStoreResource>,
    resource: ResourceArc<WasiResourceWrapper>,
    _method_name: String,
    params: Vec<Term<'a>>,
) -> NifResult<Term<'a>> {
    let store = store_resource
        .inner
        .lock()
        .map_err(|e| Error::Term(Box::new(format!("Could not lock store: {}", e))))?;

    // Validate store ownership
    if resource.store_id != store.data().store_id {
        return Err(Error::Term(Box::new(
            "Resource does not belong to this store".to_string(),
        )));
    }

    // Convert Elixir terms to wasmtime Vals
    let vals: NifResult<Vec<Val>> = params.into_iter().map(|t| convert_term_to_val(t)).collect();
    let _vals = vals?;

    // Get the resource from the wrapper
    let _resource_any = resource
        .inner
        .lock()
        .map_err(|e| Error::Term(Box::new(format!("Could not lock resource: {}", e))))?;

    // Here we would dispatch the method call through wasmtime
    // For now, this is a placeholder
    // Calling method on host resource

    // Return a placeholder result
    Ok(atoms::ok().encode(env))
}
