use std::collections::HashMap;
use std::hash;

use crate::component::ComponentInstanceResource;
use crate::component::ComponentResource;
use crate::store::ComponentStoreData;
use crate::store::ComponentStoreResource;
use crate::store::{StoreOrCaller, StoreOrCallerResource};

use rustler::Encoder;
use rustler::Error;
use rustler::MapIterator;
use rustler::NifResult;
use rustler::ResourceArc;

use rustler::Term;
use rustler::TermType;
use wasmtime::component::types::List;
use wasmtime::component::types::Record;
use wasmtime::component::Linker;
use wasmtime::component::Type;
use wasmtime::component::Val;
use wasmtime::Store;
use wasmtime::ValType;

#[rustler::nif(name = "exec_func")]
pub fn exec_func_impl(
    component_store_resource: ResourceArc<ComponentStoreResource>,
    instance_resource: ResourceArc<ComponentInstanceResource>,
    func_name: String,
    params: Term,
) -> NifResult<ValWrapper> {
    let given_params = match params.decode::<Vec<Term>>() {
        Ok(vec) => vec,
        Err(e) => return Err(e),
    };
    let component_store: &mut Store<ComponentStoreData> =
        &mut *(component_store_resource.inner.lock().map_err(|e| {
            rustler::Error::Term(Box::new(format!(
                "Could not unlock component_store resource as the mutex was poisoned: {e}"
            )))
        })?);

    let instance = &mut instance_resource.inner.lock().map_err(|e| {
        rustler::Error::Term(Box::new(format!(
            "Could not unlock component instance resource as the mutex was poisoned: {e}"
        )))
    })?;

    let func = instance
        .get_func(&mut *component_store, func_name)
        .expect("function not found");

    let paramTypes = func.params(&mut *component_store);
    let converted_params = convert_params(&mut *component_store, paramTypes, given_params)?;
    let results_count = func.results(&*component_store).len();

    let mut result = vec![Val::Bool(false); results_count];
    func.call(
        &mut *component_store,
        converted_params.as_slice(),
        &mut result,
    );
    func.post_return(&mut *component_store);
    Ok(ValWrapper { val: result })
}

fn convert_params(
    componentStore: &mut Store<ComponentStoreData>,
    paramTypes: Box<[Type]>,
    param_terms: Vec<Term>,
) -> Result<Vec<Val>, Error> {
    let mut params = Vec::with_capacity(paramTypes.len());

    for (i, (param_term, paramType)) in param_terms.iter().zip(paramTypes.iter()).enumerate() {
        let param = elixir_to_component_val(param_term, paramType)?;
        params.push(param);
    }
    Ok(params)
}

fn elixir_to_component_val(param_term: &Term, param_type: &Type) -> Result<Val, Error> {
    let term_type = param_term.get_type();
    match (term_type, param_type) {
        (TermType::Binary, Type::String) => Ok(Val::String(param_term.decode::<String>()?)),
        (TermType::Integer, Type::U16) => Ok(Val::U16(param_term.decode::<u16>()?)),
        (TermType::List, Type::List(list)) => {
          let decoded_list  = param_term.decode::<Vec<Term>>()?;
          let list_values = decoded_list.iter().map(|term| elixir_to_component_val(term, &list.ty()).unwrap()).collect::<Vec<Val>>();
          Ok(Val::List(list_values))
        }
        (TermType::Map, Type::Record(record)) => {
            let mut kv = Vec::with_capacity(record.fields().len());

            let decoded_map = param_term.decode::<HashMap<Term, Term>>()?;
            let terms = decoded_map
                .iter()
                .map(|(key, val)| (key.decode::<String>().unwrap(), val))
                .collect::<Vec<(String, &Term)>>();
            for field in record.fields() {
                let field_term_option = terms.iter().find(|(k, _)| k == field.name);
                match field_term_option {
                    Some((_, field_term)) => {
                        let field_value = elixir_to_component_val(field_term, &field.ty)?;
                        kv.push((field.name.to_string(), field_value))
                    }
                    None => (),
                }
            }
            Ok(Val::Record(kv))
        }
        (_, _) => Ok(Val::Bool(false)),
    }
}

struct ValWrapper {
    val: Vec<Val>,
}

impl Encoder for ValWrapper {
    fn encode<'a>(&self, env: rustler::Env<'a>) -> Term<'a> {
        match self.val.len() {
            1 => convertTerm(self.val.iter().next().unwrap(), env),
            _ => self
                .val
                .iter()
                .map(|term| convertTerm(term, env))
                .collect::<Vec<Term>>()
                .encode(env),
        }
    }
}

fn convertTerm<'a>(term: &Val, env: rustler::Env<'a>) -> Term<'a> {
    match term {
        Val::String(string) => string.encode(env),
        Val::List(list) => list
            .iter()
            .map(|val| convertTerm(val, env))
            .collect::<Vec<Term<'a>>>()
            .encode(env),
        Val::Record(record) => {
            let converted_pairs = record
                .iter()
                .map(|(key, val)| (key, convertTerm(val, env)))
                .collect::<Vec<(&String, Term<'a>)>>();
            Term::map_from_pairs(env, converted_pairs.as_slice()).unwrap()
            // String::from("wut").encode(env)
        }
        _ => String::from("wut").encode(env),
    }
}
