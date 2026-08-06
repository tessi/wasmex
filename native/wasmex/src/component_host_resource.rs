use std::collections::HashMap;
use std::sync::Mutex;

use rustler::env::SavedTerm;
use rustler::{Encoder, Error, OwnedEnv, Term};
use wasmtime::component::{ResourceDynamic, ResourceType, Type, Val};
use wasmtime::StoreContextMut;

use crate::component_type_conversion::{term_to_val_with_resource, val_to_term_with_resource};
use crate::store::ComponentStoreData;

struct StoredTerm {
    env: OwnedEnv,
    term: SavedTerm,
    type_id: u32,
}

impl StoredTerm {
    fn new(term: Term, type_id: u32) -> Self {
        let env = OwnedEnv::new();
        let term = env.save(term);
        Self { env, term, type_id }
    }

    fn copy_to<'a>(&self, env: rustler::Env<'a>) -> Term<'a> {
        self.env
            .run(|source_env| self.term.load(source_env).in_env(env))
    }
}

struct RegistryInner {
    next_rep: u32,
    next_type_id: u32,
    values: HashMap<u32, StoredTerm>,
    types: Vec<(ResourceType, u32)>,
}

pub(crate) struct HostResourceRegistry {
    inner: Mutex<RegistryInner>,
}

impl HostResourceRegistry {
    pub(crate) fn new() -> Self {
        Self {
            inner: Mutex::new(RegistryInner {
                next_rep: 1,
                next_type_id: 1,
                values: HashMap::new(),
                types: Vec::new(),
            }),
        }
    }

    pub(crate) fn register_type(&self) -> Result<(u32, ResourceType), String> {
        let mut inner = self
            .inner
            .lock()
            .map_err(|error| format!("Could not lock host resource registry: {error}"))?;
        let type_id = inner.next_type_id;
        inner.next_type_id = inner
            .next_type_id
            .checked_add(1)
            .ok_or_else(|| "Host resource type identifier overflow".to_string())?;
        let ty = ResourceType::host_dynamic(type_id);
        inner.types.push((ty, type_id));
        Ok((type_id, ty))
    }

    fn type_id(&self, ty: ResourceType) -> Result<u32, Error> {
        let inner = self.inner.lock().map_err(|error| {
            Error::Term(Box::new(format!(
                "Could not lock host resource registry: {error}"
            )))
        })?;
        inner
            .types
            .iter()
            .find_map(|(registered, type_id)| (*registered == ty).then_some(*type_id))
            .ok_or_else(|| Error::Term(Box::new("Unknown host resource type")))
    }

    fn insert(&self, term: Term, type_id: u32) -> Result<u32, Error> {
        let mut inner = self.inner.lock().map_err(|error| {
            Error::Term(Box::new(format!(
                "Could not lock host resource registry: {error}"
            )))
        })?;
        let rep = inner.next_rep;
        inner.next_rep = inner
            .next_rep
            .checked_add(1)
            .ok_or_else(|| Error::Term(Box::new("Host resource identifier overflow")))?;
        inner.values.insert(rep, StoredTerm::new(term, type_id));
        Ok(rep)
    }

    fn remove_all(&self, reps: &[u32]) {
        if let Ok(mut inner) = self.inner.lock() {
            for rep in reps {
                inner.values.remove(rep);
            }
        }
    }

    pub(crate) fn take_term(&self, rep: u32) -> Result<StoredHostTerm, String> {
        let mut inner = self
            .inner
            .lock()
            .map_err(|error| format!("Could not lock host resource registry: {error}"))?;
        inner
            .values
            .remove(&rep)
            .map(StoredHostTerm)
            .ok_or_else(|| format!("Host resource `{rep}` has already been moved or dropped"))
    }

    fn resource_to_term<'a>(
        &self,
        resource: wasmtime::component::ResourceAny,
        env: rustler::Env<'a>,
        store: &mut StoreContextMut<'_, ComponentStoreData>,
    ) -> Result<Term<'a>, String> {
        let dynamic = resource
            .try_into_resource_dynamic(&mut *store)
            .map_err(|error| format!("Could not lift host resource: {error}"))?;
        let rep = dynamic.rep();
        let type_id = dynamic.ty();
        let mut inner = self
            .inner
            .lock()
            .map_err(|error| format!("Could not lock host resource registry: {error}"))?;
        if dynamic.owned() {
            let stored = inner.values.remove(&rep).ok_or_else(|| {
                format!("Host resource `{rep}` has already been moved or dropped")
            })?;
            if stored.type_id != type_id {
                return Err(format!(
                    "Host resource type mismatch: expected {}, got {}",
                    stored.type_id, type_id
                ));
            }
            Ok(stored.copy_to(env))
        } else {
            let stored = inner.values.get(&rep).ok_or_else(|| {
                format!("Host resource `{rep}` has already been moved or dropped")
            })?;
            if stored.type_id != type_id {
                return Err(format!(
                    "Host resource type mismatch: expected {}, got {}",
                    stored.type_id, type_id
                ));
            }
            Ok(stored.copy_to(env))
        }
    }

    pub(crate) fn vals_to_terms<'a>(
        &self,
        values: &[Val],
        env: rustler::Env<'a>,
        store: &mut StoreContextMut<'_, ComponentStoreData>,
    ) -> Result<Vec<Term<'a>>, String> {
        let mut conversion_error = None;
        let mut encode_resource = |resource, env| match self.resource_to_term(resource, env, store)
        {
            Ok(term) => term,
            Err(reason) => {
                conversion_error = Some(reason);
                "Unsupported host resource".encode(env)
            }
        };
        let terms = values
            .iter()
            .map(|value| val_to_term_with_resource(value, env, vec![], &mut encode_resource))
            .collect();
        match conversion_error {
            Some(reason) => Err(reason),
            None => Ok(terms),
        }
    }

    pub(crate) fn term_to_val(
        &self,
        term: &Term,
        ty: &Type,
        store: &mut StoreContextMut<'_, ComponentStoreData>,
    ) -> Result<Val, Error> {
        let mut inserted = Vec::new();
        let mut lowered = Vec::new();
        let result = term_to_val_with_resource(
            term,
            ty,
            vec![],
            &mut |resource_term, resource_type, owned| {
                if !owned {
                    return Err(Error::Term(Box::new(
                        "Returning borrowed host resources is not supported",
                    )));
                }
                let type_id = self.type_id(resource_type)?;
                let rep = self.insert(*resource_term, type_id)?;
                inserted.push(rep);
                match ResourceDynamic::new_own(rep, type_id).try_into_resource_any(&mut *store) {
                    Ok(resource) => {
                        lowered.push(resource);
                        Ok(Val::Resource(resource))
                    }
                    Err(error) => {
                        self.remove_all(&[rep]);
                        Err(Error::Term(Box::new(error.to_string())))
                    }
                }
            },
        );
        if result.is_err() {
            for resource in lowered {
                let _ = resource.try_into_resource_dynamic(&mut *store);
            }
            self.remove_all(&inserted);
        }
        result
    }
}

pub(crate) struct StoredHostTerm(StoredTerm);

impl StoredHostTerm {
    pub(crate) fn copy_to<'a>(&self, env: rustler::Env<'a>) -> Term<'a> {
        self.0.copy_to(env)
    }
}
