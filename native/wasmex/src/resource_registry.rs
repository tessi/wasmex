use rustler::ResourceArc;
use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Mutex;

use crate::wasi_resource::WasiResourceWrapper;

pub struct ResourceRegistry {
    resources: Mutex<HashMap<usize, ResourceArc<WasiResourceWrapper>>>,
    next_id: AtomicUsize,
    store_id: usize,
}

impl ResourceRegistry {
    pub fn new(store_id: usize) -> Self {
        ResourceRegistry {
            resources: Mutex::new(HashMap::new()),
            next_id: AtomicUsize::new(1),
            store_id,
        }
    }

    pub fn register_resource(&self, resource: &ResourceArc<WasiResourceWrapper>) -> usize {
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);

        let mut resources = self.resources.lock().unwrap();
        resources.insert(id, resource.clone());

        id
    }

    pub fn get_resource(&self, id: usize) -> Option<ResourceArc<WasiResourceWrapper>> {
        let resources = self.resources.lock().unwrap();
        resources.get(&id).cloned()
    }

    pub fn remove_resource(&self, id: usize) -> bool {
        let mut resources = self.resources.lock().unwrap();
        resources.remove(&id).is_some()
    }

    pub fn cleanup_dropped_resources(&self) {
        // With ResourceArc, we don't need to clean up weak references
        // Resources will be dropped when their reference count reaches zero
    }

    pub fn validate_resource_store(&self, resource: &WasiResourceWrapper) -> bool {
        resource.store_id() == self.store_id
    }

    pub fn count_active_resources(&self) -> usize {
        let resources = self.resources.lock().unwrap();
        resources.len()
    }

    pub fn clear(&self) {
        let mut resources = self.resources.lock().unwrap();
        resources.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_resource_registration() {
        let registry = ResourceRegistry::new(1);
        assert_eq!(registry.count_active_resources(), 0);
    }

    #[test]
    fn test_cleanup_dropped_resources() {
        let registry = ResourceRegistry::new(1);

        // Test cleanup doesn't crash on empty registry
        registry.cleanup_dropped_resources();
        assert_eq!(registry.count_active_resources(), 0);
    }
}
