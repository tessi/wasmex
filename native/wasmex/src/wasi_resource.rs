use rustler::ResourceArc;
use std::sync::Mutex;
use wasmtime::component::{ResourceAny, Val};

#[derive(Debug, Clone)]
pub enum ResourceType {
    GuestDefined { type_name: String },
    HostDefined { type_name: String },
}

pub struct WasiResourceWrapper {
    pub inner: Mutex<ResourceAny>,
    pub resource_type: ResourceType,
    pub is_owned: bool,
    pub store_id: usize, // Link to the store that owns this resource
}

#[rustler::resource_impl()]
impl rustler::Resource for WasiResourceWrapper {}

impl Drop for WasiResourceWrapper {
    fn drop(&mut self) {
        #[cfg(debug_assertions)]
        {
            let type_name = match &self.resource_type {
                ResourceType::GuestDefined { type_name } => type_name.clone(),
                ResourceType::HostDefined { type_name } => type_name.clone(),
            };
            eprintln!(
                "Dropping WasiResourceWrapper: type={}, store_id={}, owned={}",
                type_name, self.store_id, self.is_owned
            );
        }
    }
}

impl WasiResourceWrapper {
    pub fn new(resource: ResourceAny, store_id: usize) -> Self {
        let is_owned = resource.owned();

        // Determine resource type based on whether it's host or guest
        // For now, we'll default to guest-defined until we can properly detect
        let resource_type = ResourceType::GuestDefined {
            type_name: "unknown".to_string(), // TODO: Get actual type name from resource metadata
        };

        WasiResourceWrapper {
            inner: Mutex::new(resource),
            resource_type,
            is_owned,
            store_id,
        }
    }

    pub fn is_owned(&self) -> bool {
        self.is_owned
    }

    pub fn store_id(&self) -> usize {
        self.store_id
    }
}

pub fn val_to_resource_wrapper(
    val: Val,
    store_id: usize,
) -> Result<ResourceArc<WasiResourceWrapper>, String> {
    match val {
        Val::Resource(resource_any) => {
            let wrapper = WasiResourceWrapper::new(resource_any, store_id);
            Ok(ResourceArc::new(wrapper))
        }
        _ => Err("Expected a resource value".to_string()),
    }
}

pub fn resource_wrapper_to_val(wrapper: &ResourceArc<WasiResourceWrapper>) -> Result<Val, String> {
    let resource = wrapper
        .inner
        .lock()
        .map_err(|e| format!("Could not lock resource: {}", e))?;

    // Clone the ResourceAny - this is safe as it just clones the handle
    Ok(Val::Resource(*resource))
}
