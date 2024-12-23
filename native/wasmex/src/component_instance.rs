use std::collections::HashMap;
use std::sync::{Condvar, Mutex};

use crate::atoms;
use crate::component::ComponentInstanceResource;
use crate::store::ComponentStoreData;
use crate::store::ComponentStoreResource;

use convert_case::{Case, Casing};

use rustler::types::atom::nil;
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

pub struct ComponentCallbackTokenResource {
    pub token: ComponentCallbackToken,
}

#[rustler::resource_impl()]
impl rustler::Resource for ComponentCallbackTokenResource {}

pub struct ComponentCallbackToken {
    pub continue_signal: Condvar,
    pub return_types: Vec<Type>,
    pub return_values: Mutex<Option<(bool, Vec<Val>)>>,
}

#[rustler::nif(name = "component_call_function")]
pub fn component_call_function<'a>(
    env: rustler::Env<'a>,
    component_store_resource: ResourceArc<ComponentStoreResource>,
    instance_resource: ResourceArc<ComponentInstanceResource>,
    func_name: String,
    given_params: Vec<Term>,
) -> NifResult<Term<'a>> {
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

    let function_result = instance.get_func(&mut *component_store, func_name.clone());
    let function = match function_result {
        Some(func) => func,
        None => return Ok(env.error_tuple(format!("Function {func_name} not exported."))),
    };

    let param_types = function.params(&mut *component_store);
    let converted_params = match convert_params(&param_types, given_params) {
        Ok(params) => params,
        Err(e) => return Err(e)
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
            Ok(encode_result(env, result))
        }
        Err(err) => Err(rustler::Error::RaiseTerm(Box::new(format!(
            "Error executing function: {err}"
        )))),
    }
}

fn convert_params(param_types: &[Type], param_terms: Vec<Term>) -> Result<Vec<Val>, Error> {
    let mut params = Vec::with_capacity(param_types.len());

    for (param_term, param_type) in param_terms.iter().zip(param_types.iter()) {
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
        (TermType::Float, Type::Float32) => Ok(Val::Float32(param_term.decode::<f32>()?)),
        (TermType::Float, Type::Float64) => Ok(Val::Float64(param_term.decode::<f64>()?)),

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
            for (tuple_type, tuple_term) in tuple_types.zip(dedoded_tuple) {
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
                .map(|(key_term, val)| (term_to_field_name(key_term), val))
                .collect::<Vec<(String, &Term)>>();
            for field in record.fields() {
                let field_term_option = terms.iter().find(|(k, _)| k == field.name);
                if let Some((_, field_term)) = field_term_option {
                    let field_value = term_to_val(field_term, &field.ty)?;
                    kv.push((field.name.to_string(), field_value))
                }
            }
            Ok(Val::Record(kv))
        }
        (TermType::Atom, Type::Option(option_type)) => {
            let the_atom = param_term.atom_to_string()?;
            if the_atom == "nil" {
                Ok(Val::Option(None))
            } else {
                let converted_val = term_to_val(param_term, &option_type.ty())?;
                Ok(Val::Option(Some(Box::new(converted_val))))
            }
        }
        (_term_type, Type::Option(option_type)) => {
            let converted_val = term_to_val(param_term, &option_type.ty())?;
            Ok(Val::Option(Some(Box::new(converted_val))))
        }
        (term_type, val_type) => Err(rustler::Error::Term(Box::new(format!(
            "Could not convert {:?} to {:?}",
            term_type, val_type
        )))),
    }
}

fn term_to_field_name(key_term: &Term) -> String {
    match key_term.get_type() {
        TermType::Atom => key_term.atom_to_string().unwrap().to_case(Case::Kebab),
        _ => key_term.decode::<String>().unwrap().to_case(Case::Kebab),
    }
}

fn field_name_to_term<'a>(env: &rustler::Env<'a>, field_name: &str) -> Term<'a> {
    rustler::serde::atoms::str_to_term(env, &field_name.to_case(Case::Snake)).unwrap()
}

fn encode_result(env: rustler::Env, vals: Vec<Val>) -> Term {
    let result_term = match vals.len() {
        1 => val_to_term(vals.first().unwrap(), env),
        _ => vals
            .iter()
            .map(|term| val_to_term(term, env))
            .collect::<Vec<Term>>()
            .encode(env),
    };
    make_tuple(env, &[atoms::ok().encode(env), result_term])
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
        Val::Float32(num) => num.encode(env),
        Val::Float64(num) => num.encode(env),
        Val::List(list) => list
            .iter()
            .map(|val| val_to_term(val, env))
            .collect::<Vec<Term<'a>>>()
            .encode(env),
        Val::Record(record) => {
            let converted_pairs = record
                .iter()
                .map(|(key, val)| (field_name_to_term(&env, key), val_to_term(val, env)))
                .collect::<Vec<(Term, Term)>>();
            Term::map_from_pairs(env, converted_pairs.as_slice()).unwrap()
        }
        Val::Tuple(tuple) => {
            let tuple_terms = tuple
                .iter()
                .map(|val| val_to_term(val, env))
                .collect::<Vec<Term<'a>>>();
            make_tuple(env, tuple_terms.as_slice())
        }
        Val::Option(option) => match option {
            Some(boxed_val) => val_to_term(boxed_val, env),
            None => nil().encode(env),
        },
        _ => String::from("wut").encode(env),
    }
}
