use rustler::types::atom;
use rustler::types::tuple::{self, make_tuple};
use rustler::{Encoder, Error, Term, TermType};
use std::collections::HashMap;
use wasmtime::component::{Type, Val};
use wit_parser::{Resolve, Type as WitType, TypeDef, TypeDefKind};

use crate::atoms;

pub fn term_to_val(param_term: &Term, param_type: &Type) -> Result<Val, Error> {
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
        (TermType::Integer, Type::Char) => {
            let integer = param_term.decode::<u32>()?;
            match char::from_u32(integer) {
                Some(ch) => Ok(Val::Char(ch)),
                None => Err(Error::Term(Box::new(format!(
                    "Invalid character code point: {}",
                    integer
                )))),
            }
        }
        (TermType::Binary, Type::Char) => {
            let string = param_term.decode::<String>()?;
            let mut chars = string.chars();
            // Get the first character from the string
            match chars.next() {
                Some(ch) => {
                    // Ensure it's a single character
                    if chars.next().is_none() {
                        Ok(Val::Char(ch))
                    } else {
                        Err(Error::Term(Box::new(
                            "Expected a single character, got multiple characters".to_string(),
                        )))
                    }
                }
                None => Err(Error::Term(Box::new(
                    "Empty string, expected a character".to_string(),
                ))),
            }
        }
        (TermType::List, Type::Char) => {
            let list = param_term.decode::<Vec<Term>>()?;
            if list.len() != 1 {
                Err(Error::Term(Box::new("Expected a single char")))
            } else {
                let char_code = list[0].decode::<u32>()?;
                match char::from_u32(char_code) {
                    Some(ch) => Ok(Val::Char(ch)),
                    None => Err(Error::Term(Box::new(format!(
                        "Invalid character code point: {}",
                        char_code
                    )))),
                }
            }
        }
        (TermType::Float, Type::Float32) => Ok(Val::Float32(param_term.decode::<f32>()?)),
        (TermType::Float, Type::Float64) => Ok(Val::Float64(param_term.decode::<f64>()?)),
        (_term_type, Type::Bool) => Ok(Val::Bool(rustler::types::atom::is_truthy(*param_term))),
        (TermType::List, Type::List(list)) => {
            let decoded_list = param_term.decode::<Vec<Term>>()?;
            let mut list_values = Vec::with_capacity(decoded_list.len());
            for term in decoded_list {
                let val = term_to_val(&term, &list.ty())?;
                list_values.push(val);
            }
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
                let field_term_option = terms
                    .iter()
                    .find(|(field_name, _)| field_name == field.name);
                if let Some((_, field_term)) = field_term_option {
                    let field_value = term_to_val(field_term, &field.ty)?;
                    kv.push((field.name.to_string(), field_value))
                }
            }
            if kv.len() != record.fields().len() {
                let missing_fields = record
                    .fields()
                    .filter(|field| !terms.iter().any(|(name, _)| name == field.name))
                    .collect::<Vec<_>>();
                return Err(Error::Term(Box::new(format!(
                    "Expected {} fields, got {} - missing fields: {}",
                    record.fields().len(),
                    kv.len(),
                    missing_fields
                        .iter()
                        .map(|field| field.name)
                        .collect::<Vec<_>>()
                        .join(", ")
                ))));
            }
            Ok(Val::Record(kv))
        }
        (TermType::Atom, Type::Option(_option_type)) => {
            let none_atom = param_term.atom_to_string()?;
            if none_atom == "none" {
                Ok(Val::Option(None))
            } else {
                Err(Error::Term(Box::new(format!(
                    "Invalid atom: {}, expected ':none' or '{{:some, term}}' tuple",
                    none_atom
                ))))
            }
        }
        (TermType::Tuple, Type::Option(option_type)) => {
            let tuple_terms = tuple::get_tuple(*param_term)?;
            let first_term = tuple_terms.first().ok_or(Error::Term(Box::new(
                "Option-tuple expected to have a first element",
            )))?;
            let second_term = tuple_terms.get(1).ok_or(Error::Term(Box::new(
                "Option-tuple expected to have a second element",
            )))?;

            let some_atom = first_term.atom_to_string()?;
            if some_atom == "some" {
                let inner_val = term_to_val(second_term, &option_type.ty())?;
                Ok(Val::Option(Some(Box::new(inner_val))))
            } else {
                Err(Error::Term(Box::new(format!(
                    "Invalid atom: {}, expected ':some'",
                    some_atom
                ))))
            }
        }
        (TermType::Atom, Type::Enum(enum_type)) => {
            let case_name = param_term.atom_to_string()?;
            let enum_val = enum_type.names().find(|v| *v == case_name);
            if let Some(enum_val) = enum_val {
                Ok(Val::Enum(enum_val.to_string()))
            } else {
                Err(Error::Term(Box::new(format!(
                    "Enum value not found: {}",
                    case_name
                ))))
            }
        }
        (TermType::Binary, Type::Enum(enum_type)) => {
            let case_name = param_term.decode::<String>()?;
            let enum_val = enum_type.names().find(|v| *v == case_name);
            if let Some(enum_val) = enum_val {
                Ok(Val::Enum(enum_val.to_string()))
            } else {
                Err(Error::Term(Box::new(format!(
                    "Enum value not found: {}",
                    case_name
                ))))
            }
        }
        (TermType::Atom, Type::String) => Ok(Val::String(param_term.atom_to_string()?)),
        (TermType::Atom, Type::Result(result_type)) => {
            let result_kind = param_term.atom_to_string()?;
            if result_kind == "ok" {
                if let Some(_ok_type) = result_type.ok() {
                    Err(Error::Term(Box::new(
                        "Result-type expected to have an 'ok' tuple, but got :ok atom",
                    )))
                } else {
                    Ok(Val::Result(Ok(None)))
                }
            } else if result_kind == "error" {
                if let Some(_error_type) = result_type.err() {
                    Err(Error::Term(Box::new(
                        "Result-type expected to have an 'error' tuple, but got :error atom",
                    )))
                } else {
                    Ok(Val::Result(Err(None)))
                }
            } else {
                Err(Error::Term(Box::new(format!(
                    "Invalid atom: {}, expected ':ok' or ':error' as result",
                    result_kind
                ))))
            }
        }
        (TermType::Tuple, Type::Result(result_type)) => {
            let tuple_term = tuple::get_tuple(*param_term)?;
            let first_term = tuple_term.first().ok_or(Error::Term(Box::new(
                "Result-tuple expected to have a first element",
            )))?;
            let second_term = tuple_term.get(1).ok_or(Error::Term(Box::new(
                "Result-tuple expected to have a second element",
            )))?;

            let result_kind = first_term.atom_to_string()?;
            if result_kind == "ok" {
                if let Some(ok_type) = result_type.ok() {
                    let ok_val = term_to_val(second_term, &ok_type)?;
                    Ok(Val::Result(Ok(Some(Box::new(ok_val)))))
                } else {
                    Err(Error::Term(Box::new(
                        "Result-type expected to have an :ok atom, but got 'ok' tuple",
                    )))
                }
            } else if result_kind == "error" {
                if let Some(err_type) = result_type.err() {
                    let err_val = term_to_val(second_term, &err_type)?;
                    Ok(Val::Result(Err(Some(Box::new(err_val)))))
                } else {
                    Err(Error::Term(Box::new(
                        "Result-type expected to have an :error atom, but got 'error' tuple",
                    )))
                }
            } else {
                Err(Error::Term(Box::new(format!(
                    "Invalid atom: {}, expected ':ok' or ':error' as first element in result-tuple",
                    result_kind
                ))))
            }
        }
        (TermType::Atom, Type::Variant(variant_type)) => {
            let case_name = param_term.atom_to_string()?;
            // Check if the case exists in the variant
            if variant_type.cases().any(|case| case.name == case_name) {
                Ok(Val::Variant(case_name, None))
            } else {
                Err(Error::Term(Box::new(format!(
                    "Variant case not found: {}",
                    case_name
                ))))
            }
        }
        (TermType::Tuple, Type::Variant(variant_type)) => {
            let tuple_term = tuple::get_tuple(*param_term)?;
            let case_term = tuple_term.first().ok_or(Error::Term(Box::new(
                "Variant-tuple expected to have a first element",
            )))?;
            let payload_term = tuple_term.get(1).ok_or(Error::Term(Box::new(
                "Variant-tuple expected to have a second element",
            )))?;

            if case_term.get_type() != TermType::Atom {
                return Err(Error::Term(Box::new(
                    "First element of variant tuple must be an atom".to_string(),
                )));
            }

            let case_name = case_term.atom_to_string()?;
            // Find the matching case and its type
            let case = variant_type.cases().find(|case| case.name == case_name);

            if let Some(case) = case {
                if let Some(case_type) = case.ty {
                    let payload_val = term_to_val(payload_term, &case_type)?;
                    Ok(Val::Variant(case_name, Some(Box::new(payload_val))))
                } else {
                    Ok(Val::Variant(case_name, None))
                }
            } else {
                Err(Error::Term(Box::new(format!(
                    "Variant case not found: {}",
                    case_name
                ))))
            }
        }
        (TermType::Map, Type::Flags(flags_type)) => {
            let decoded_map = param_term.decode::<HashMap<Term, Term>>()?;
            let mut flags = vec![];

            // Convert the map entries to flag names and values
            for (flag_term, value_term) in decoded_map {
                let flag_name = term_to_field_name(&flag_term);

                // Check if the flag exists in the type
                if flags_type.names().any(|name| name == flag_name) {
                    let is_set = value_term.decode::<bool>()?;
                    if is_set {
                        flags.push(flag_name);
                    }
                } else {
                    return Err(Error::Term(Box::new(format!(
                        "Flag not found: {}",
                        flag_name
                    ))));
                }
            }

            Ok(Val::Flags(flags))
        }
        (term_type, val_type) => Err(rustler::Error::Term(Box::new(format!(
            "Could not convert {:?} to {:?}",
            term_type, val_type
        )))),
    }
}

pub fn val_to_term<'a>(val: &Val, env: rustler::Env<'a>) -> Term<'a> {
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
        Val::Float32(float) => float.encode(env),
        Val::Float64(float) => float.encode(env),
        Val::Char(ch) => ch.to_string().encode(env),
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
            Some(boxed_val) => {
                let inner_term = val_to_term(boxed_val, env);
                (atoms::some(), inner_term).encode(env)
            }
            None => atoms::none().encode(env),
        },
        Val::Enum(enum_val) => rustler::serde::atoms::str_to_term(&env, enum_val).unwrap(),
        Val::Result(result) => match result {
            Ok(maybe_val) => {
                if let Some(inner_val) = maybe_val {
                    let inner_term = val_to_term(inner_val, env);
                    (atom::ok(), inner_term).encode(env)
                } else {
                    atom::ok().encode(env)
                }
            }
            Err(maybe_val) => {
                if let Some(inner_val) = maybe_val {
                    let inner_term = val_to_term(inner_val, env);
                    (atom::error(), inner_term).encode(env)
                } else {
                    atom::error().encode(env)
                }
            }
        },
        Val::Variant(case_name, payload) => {
            let atom = rustler::serde::atoms::str_to_term(&env, case_name).unwrap();

            match payload {
                Some(boxed_val) => {
                    let payload_term = val_to_term(boxed_val, env);
                    (atom, payload_term).encode(env)
                }
                None => atom,
            }
        }
        Val::Flags(flags) => {
            // Create an empty map
            let mut map_term = rustler::Term::map_new(env);

            // Add each set flag as a key with value true
            for flag in flags {
                let key = field_name_to_term(&env, flag);
                let value = true.encode(env);
                map_term = map_term.map_put(key, value).unwrap();
            }

            map_term
        }
        _ => String::from("Unsupported type").encode(env),
    }
}

pub fn vals_to_terms<'a>(vals: &[Val], env: rustler::Env<'a>) -> Vec<Term<'a>> {
    vals.iter()
        .map(|val| val_to_term(val, env))
        .collect::<Vec<Term<'a>>>()
}

pub fn term_to_field_name(key_term: &Term) -> String {
    // return "" (empty string) in the error case, which makes the field name mapping
    // to be skipped for that field
    match key_term.get_type() {
        TermType::Atom => key_term.atom_to_string().unwrap(),
        TermType::Binary => key_term.decode::<String>().unwrap_or("".to_string()),
        _ => "".to_string(),
    }
}

pub fn field_name_to_term<'a>(env: &rustler::Env<'a>, field_name: &str) -> Term<'a> {
    rustler::serde::atoms::str_to_term(env, field_name).unwrap()
}

pub fn convert_params(param_types: &[Type], param_terms: Vec<Term>) -> Result<Vec<Val>, Error> {
    let mut params = Vec::with_capacity(param_types.len());

    for (param_term, param_type) in param_terms.iter().zip(param_types.iter()) {
        let param = term_to_val(param_term, param_type)?;
        params.push(param);
    }
    Ok(params)
}

pub fn encode_result<'a>(env: &rustler::Env<'a>, vals: Vec<Val>, from: Term<'a>) -> Term<'a> {
    let result_term = match vals.len() {
        1 => val_to_term(vals.first().unwrap(), *env),
        _ => vals
            .iter()
            .map(|term| val_to_term(term, *env))
            .collect::<Vec<Term>>()
            .encode(*env),
    };
    make_tuple(
        *env,
        &[
            atoms::returned_function_call().encode(*env),
            make_tuple(*env, &[atoms::ok().encode(*env), result_term]),
            from,
        ],
    )
}

pub fn convert_result_term(
    result_term: Term,
    wit_type: &WitType,
    wit_resolver: &Resolve,
) -> Result<Val, Error> {
    match wit_type {
        WitType::Bool => Ok(Val::Bool(rustler::types::atom::is_truthy(result_term))),
        WitType::U8 => Ok(Val::U8(result_term.decode::<u8>()?)),
        WitType::U16 => Ok(Val::U16(result_term.decode::<u16>()?)),
        WitType::U32 => Ok(Val::U32(result_term.decode::<u32>()?)),
        WitType::U64 => Ok(Val::U64(result_term.decode::<u64>()?)),
        WitType::S8 => Ok(Val::S8(result_term.decode::<i8>()?)),
        WitType::S16 => Ok(Val::S16(result_term.decode::<i16>()?)),
        WitType::S32 => Ok(Val::S32(result_term.decode::<i32>()?)),
        WitType::S64 => Ok(Val::S64(result_term.decode::<i64>()?)),
        WitType::F32 => Ok(Val::Float32(result_term.decode::<f32>()?)),
        WitType::F64 => Ok(Val::Float64(result_term.decode::<f64>()?)),
        WitType::Char => match result_term.get_type() {
            TermType::Integer => Ok(Val::Char(result_term.decode::<u32>()?.try_into().map_err(
                |e| Error::Term(Box::new(format!("Could not convert u32 to char: {}", e))),
            )?)),
            TermType::Binary => {
                let str = result_term.decode::<String>()?;
                if let Some(char) = str.chars().next() {
                    Ok(Val::Char(char))
                } else {
                    Err(Error::Term(Box::new("Expected a single char")))
                }
            }
            TermType::List => {
                let list = result_term.decode::<Vec<Term>>()?;
                if list.len() != 1 {
                    Err(Error::Term(Box::new("Expected a single char")))
                } else {
                    Ok(Val::Char(list[0].decode::<u32>()?.try_into().map_err(
                        |e| Error::Term(Box::new(format!("Could not convert u32 to char: {}", e))),
                    )?))
                }
            }
            _ => Err(Error::Atom("unsupported_type_conversion")),
        },
        WitType::String => Ok(Val::String(result_term.decode::<String>()?)),
        WitType::Id(type_id) => {
            let complex_type = &wit_resolver.types[*type_id];
            convert_complex_result(result_term, complex_type, wit_resolver)
        }
        // You might want to handle other cases like Id, etc.
        _ => Err(Error::Term(Box::new("Unsupported type conversion"))),
    }
}

fn convert_complex_result(
    result_term: Term,
    complex_type: &TypeDef,
    wit_resolver: &Resolve,
) -> Result<Val, Error> {
    match &complex_type.kind {
        TypeDefKind::List(list_type) => {
            let decoded_list = result_term.decode::<Vec<Term>>()?;
            let list_values = decoded_list
                .iter()
                .map(|term| convert_result_term(*term, list_type, wit_resolver))
                .collect::<Result<Vec<Val>, Error>>()?;
            Ok(Val::List(list_values))
        }
        TypeDefKind::Record(record_type) => {
            let mut record_fields = Vec::with_capacity(record_type.fields.len());
            let decoded_map = result_term.decode::<HashMap<Term, Term>>()?;
            let field_term_tuples = decoded_map
                .iter()
                .map(|(key_term, val)| (term_to_field_name(key_term), val))
                .collect::<Vec<(String, &Term)>>();
            for field in &record_type.fields {
                let field_term_option = field_term_tuples.iter().find(|(k, _)| *k == field.name);
                if let Some((_, field_term)) = field_term_option {
                    let field_value = convert_result_term(**field_term, &field.ty, wit_resolver)?;
                    record_fields.push((field.name.to_string(), field_value))
                }
            }
            Ok(Val::Record(record_fields))
        }
        TypeDefKind::Tuple(tuple_type) => {
            let tuple_types = tuple_type.types.clone();
            let decoded_tuple = tuple::get_tuple(result_term)?;
            let mut tuple_vals: Vec<Val> = Vec::with_capacity(tuple_types.len());
            for (tuple_type, tuple_term) in tuple_types.iter().zip(decoded_tuple) {
                let component_val = convert_result_term(tuple_term, tuple_type, wit_resolver)?;
                tuple_vals.push(component_val);
            }
            Ok(Val::Tuple(tuple_vals))
        }
        TypeDefKind::Result(result_type) => {
            if result_term.is_atom() {
                let result_kind = result_term.atom_to_string()?;
                if result_kind == "ok" {
                    if let Some(_ok_type) = result_type.ok {
                        Err(Error::Term(Box::new(
                            "Result-type expected to have an 'ok' tuple, but got :ok atom",
                        )))
                    } else {
                        Ok(Val::Result(Ok(None)))
                    }
                } else if result_kind == "error" {
                    if let Some(_error_type) = result_type.err {
                        Err(Error::Term(Box::new(
                            "Result-type expected to have an 'error' tuple, but got :error atom",
                        )))
                    } else {
                        Ok(Val::Result(Err(None)))
                    }
                } else {
                    Err(Error::Term(Box::new(format!(
                        "Invalid atom: {}, expected ':ok' or ':error' as result",
                        result_kind
                    ))))
                }
            } else if result_term.is_tuple() {
                let decoded_tuple = tuple::get_tuple(result_term)?;
                let first_term = decoded_tuple
                    .first()
                    .ok_or(Error::Term(Box::new("Invalid tuple")))?;
                let second_term = decoded_tuple
                    .get(1)
                    .ok_or(Error::Term(Box::new("Invalid tuple")))?;

                let ok_atom = first_term.atom_to_string()?;
                if ok_atom == "ok" {
                    if let Some(ok_type) = result_type.ok {
                        let ok_val = convert_result_term(*second_term, &ok_type, wit_resolver)?;
                        Ok(Val::Result(Ok(Some(Box::new(ok_val)))))
                    } else {
                        Ok(Val::Result(Ok(None)))
                    }
                } else if let Some(err_type) = result_type.err {
                    let err_val = convert_result_term(*second_term, &err_type, wit_resolver)?;
                    Ok(Val::Result(Err(Some(Box::new(err_val)))))
                } else {
                    Ok(Val::Result(Err(None)))
                }
            } else {
                Err(Error::Term(Box::new(
                    "Result-tuple, :ok, or :error expected",
                )))
            }
        }
        TypeDefKind::Option(option_type) => {
            if result_term.is_atom() {
                let none_atom = result_term.atom_to_string()?;
                if none_atom == "none" {
                    Ok(Val::Option(None))
                } else {
                    Err(Error::Term(Box::new(format!(
                        "Invalid atom: {}, expected ':none' or '{{:some, term}}' tuple",
                        none_atom
                    ))))
                }
            } else {
                let decoded_tuple = tuple::get_tuple(result_term)
                    .map_err(|_| Error::Term(Box::new("Option-tuple expected")))?;
                let first_term = decoded_tuple.first().ok_or(Error::Term(Box::new(
                    "Option-tuple expected to have :some as first element",
                )))?;
                let some_atom = first_term.atom_to_string().map_err(|e| {
                    Error::Term(Box::new(format!(
                        "Option-tuple expected to have :some as first element - {:?}",
                        e
                    )))
                })?;
                if some_atom != "some" {
                    return Err(Error::Term(Box::new(format!(
                        "Invalid atom: {}, expected ':some' as first element in option-tuple",
                        some_atom
                    ))));
                }
                let second_term = decoded_tuple.get(1).ok_or(Error::Term(Box::new(
                    "Option-tuple expected to have a second element",
                )))?;

                let some_val = convert_result_term(*second_term, option_type, wit_resolver)?;
                Ok(Val::Option(Some(Box::new(some_val))))
            }
        }
        TypeDefKind::Enum(enum_type) => {
            let atom = result_term.atom_to_string()?;
            let enum_val = enum_type.cases.iter().find(|v| v.name == atom);
            if let Some(enum_val) = enum_val {
                Ok(Val::Enum(enum_val.name.clone()))
            } else {
                Err(Error::Term(Box::new("Enum value not found")))
            }
        }
        TypeDefKind::Flags(flags_type) => {
            let decoded_map = result_term.decode::<HashMap<Term, Term>>()?;
            let mut flags = vec![];

            // Convert the map entries to flag names and values
            for (flag_term, value_term) in decoded_map {
                let flag_name = term_to_field_name(&flag_term);

                // Check if the flag exists in the type
                if flags_type.flags.iter().any(|flag| flag.name == flag_name) {
                    let is_set = value_term.decode::<bool>()?;
                    if is_set {
                        flags.push(flag_name);
                    }
                } else {
                    return Err(Error::Term(Box::new(format!(
                        "Flag not found: {}",
                        flag_name
                    ))));
                }
            }

            Ok(Val::Flags(flags))
        }
        TypeDefKind::Variant(variant_type) => {
            let case_name = if result_term.is_atom() {
                result_term.atom_to_string()?
            } else if result_term.is_tuple() {
                let decoded_tuple = tuple::get_tuple(result_term)
                    .map_err(|_| Error::Term(Box::new("Variant-tuple expected")))?;
                let first_term = decoded_tuple.first().ok_or(Error::Term(Box::new(
                    "Variant-tuple expected to have at least one element",
                )))?;
                first_term.atom_to_string().map_err(|_| {
                    Error::Term(Box::new(
                        "Variant-tuple expected to have an atom as first element",
                    ))
                })?
            } else {
                return Err(Error::Term(Box::new("Variant-tuple or atom expected")));
            };

            let variant_val = variant_type.cases.iter().find(|v| v.name == case_name);
            if let Some(variant_val) = variant_val {
                if let Some(payload_type) = variant_val.ty {
                    let decoded_tuple = tuple::get_tuple(result_term)
                        .map_err(|_| Error::Term(Box::new("Variant-tuple expected")))?;
                    let variant_inner_result_term = decoded_tuple.get(1).ok_or_else(|| {
                        Error::Term(Box::new("Variant-tuple expected to have a second element"))
                    })?;
                    Ok(Val::Variant(
                        variant_val.name.clone(),
                        Some(Box::new(convert_result_term(
                            *variant_inner_result_term,
                            &payload_type,
                            wit_resolver,
                        )?)),
                    ))
                } else {
                    Ok(Val::Variant(variant_val.name.clone(), None))
                }
            } else {
                Err(Error::Term(Box::new("Variant value not found")))
            }
        }
        _ => Err(Error::Term(Box::new("Unsupported type conversion"))),
    }
    // Type::String
}
