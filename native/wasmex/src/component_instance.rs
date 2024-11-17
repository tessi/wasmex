use std::collections::HashMap;

use crate::component::ComponentInstanceResource;
use crate::store::ComponentStoreData;
use crate::store::ComponentStoreResource;

use rustler::types::tuple;
use rustler::types::tuple::make_tuple;
use rustler::Encoder;
use rustler::Error;
use rustler::NifResult;
use rustler::ResourceArc;

use rustler::Term;
use rustler::TermType;
use wasmtime::component::Type;
use wasmtime::component::Val;
use wasmtime::Store;

#[rustler::nif(name = "exec_func")]
pub fn exec_func_impl(
    component_store_resource: ResourceArc<ComponentStoreResource>,
    instance_resource: ResourceArc<ComponentInstanceResource>,
    func_name: String,
    given_params: Vec<Term>,
) -> NifResult<ValWrapper> {
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

    let param_types = func.params(&mut *component_store);
    let converted_params = convert_params(param_types, given_params)?;
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
    param_types: Box<[Type]>,
    param_terms: Vec<Term>,
) -> Result<Vec<Val>, Error> {
    let mut params = Vec::with_capacity(param_types.len());

    for (i, (param_term, param_type)) in param_terms.iter().zip(param_types.iter()).enumerate() {
        let param = term_to_val(param_term, param_type)?;
        params.push(param);
    }
    Ok(params)
}

fn term_to_val(param_term: &Term, param_type: &Type) -> Result<Val, Error> {
    let term_type = param_term.get_type();
    match (term_type, param_type) {
        (TermType::Binary, Type::String) => Ok(Val::String(param_term.decode::<String>()?)),
        (TermType::Integer, Type::U8) => Ok(Val::U8(param_term.decode::<u8>()?)),
        (TermType::Integer, Type::U16) => Ok(Val::U16(param_term.decode::<u16>()?)),
        (TermType::Integer, Type::U64) => Ok(Val::U64(param_term.decode::<u64>()?)),
        (TermType::Integer, Type::U32) => Ok(Val::U32(param_term.decode::<u32>()?)),
        (TermType::Integer, Type::S8) => Ok(Val::S8(param_term.decode::<i8>()?)),
        (TermType::Integer, Type::S16) => Ok(Val::S16(param_term.decode::<i16>()?)),
        (TermType::Integer, Type::S64) => Ok(Val::S64(param_term.decode::<i64>()?)),
        (TermType::Integer, Type::S32) => Ok(Val::S32(param_term.decode::<i32>()?)),

        (TermType::Atom, Type::Bool) => Ok(Val::Bool(param_term.decode::<bool>()?)),
        (TermType::List, Type::List(list)) => {
            let decoded_list = param_term.decode::<Vec<Term>>()?;
            let list_values = decoded_list
                .iter()
                .map(|term| term_to_val(term, &list.ty()).unwrap())
                .collect::<Vec<Val>>();
            Ok(Val::List(list_values))
        }
        (TermType::Tuple, Type::Tuple(tuple)) => {
            let dedoded_tuple = tuple::get_tuple(*param_term)?;
            let tuple_types = tuple.types();
            let mut tuple_vals: Vec<Val> = Vec::with_capacity(tuple_types.len());
            for (i, (tuple_type, tuple_term)) in tuple_types.zip(dedoded_tuple).enumerate() {
                let component_val = term_to_val(&tuple_term, &tuple_type)?;
                tuple_vals.push(component_val);
            }
            Ok(Val::Tuple(tuple_vals))
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
                        let field_value = term_to_val(field_term, &field.ty)?;
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
            1 => val_to_term(self.val.iter().next().unwrap(), env),
            _ => self
                .val
                .iter()
                .map(|term| val_to_term(term, env))
                .collect::<Vec<Term>>()
                .encode(env),
        }
    }
}

fn val_to_term<'a>(val: &Val, env: rustler::Env<'a>) -> Term<'a> {
    match val {
        Val::String(string) => string.encode(env),
        Val::Bool(bool) => bool.encode(env),
        Val::U64(num) => num.encode(env),
        Val::U32(num) => num.encode(env),
        Val::U16(num) => num.encode(env),
        Val::U8(num) => num.encode(env),
        Val::S8(num) => num.encode(env),
        Val::S16(num) => num.encode(env),
        Val::S32(num) => num.encode(env),
        Val::S64(num) => num.encode(env),
        Val::List(list) => list
            .iter()
            .map(|val| val_to_term(val, env))
            .collect::<Vec<Term<'a>>>()
            .encode(env),
        Val::Record(record) => {
            let converted_pairs = record
                .iter()
                .map(|(key, val)| (key, val_to_term(val, env)))
                .collect::<Vec<(&String, Term<'a>)>>();
            Term::map_from_pairs(env, converted_pairs.as_slice()).unwrap()
            // String::from("wut").encode(env)
        }
        Val::Tuple(tuple) => {
          let tuple_terms = tuple
            .iter()
            .map(|val| val_to_term(val, env))
            .collect::<Vec<Term<'a>>>();
          make_tuple(env, tuple_terms.as_slice())
        }
        _ => String::from("wut").encode(env),
    }
}
