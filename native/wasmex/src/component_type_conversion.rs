use rustler::types::atom;
use rustler::types::tuple::{self, make_tuple};
use rustler::{Encoder, Error, Term, TermType};
use std::collections::HashMap;
use wasmtime::component::{Type, Val};
use wit_parser::{Resolve, Type as WitType, TypeDef, TypeDefKind};

use crate::atoms;

/// Convert an Elixir term to a Wasm value.
///
/// Used to for Wasm function calls from Elixir and translating params to Wasm values.
/// The opposite of this is `val_to_term` and `convert_result_term`.
pub fn term_to_val(
    param_term: &Term,
    param_type: &Type,
    mut path: Vec<String>,
) -> Result<Val, Error> {
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
                    "Invalid character code point: {integer}"
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
                        "Invalid character code point: {char_code}"
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
            for (index, term) in decoded_list.iter().enumerate() {
                path.push(format!("list[{index}]"));
                let val = term_to_val(term, &list.ty(), path.clone())?;
                path.pop();
                list_values.push(val);
            }
            Ok(Val::List(list_values))
        }
        (TermType::Tuple, Type::Tuple(tuple)) => {
            let dedoded_tuple = tuple::get_tuple(*param_term)?;
            let tuple_types = tuple.types();
            let mut tuple_vals: Vec<Val> = Vec::with_capacity(tuple_types.len());
            for (index, (tuple_type, tuple_term)) in tuple_types.zip(dedoded_tuple).enumerate() {
                path.push(format!("tuple[{index}]"));
                let component_val = term_to_val(&tuple_term, &tuple_type, path.clone())?;
                path.pop();
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
                if let Some((field_name, field_term)) = field_term_option {
                    path.push(format!("record('{field_name}')"));
                    let field_value = term_to_val(field_term, &field.ty, path.clone())?;
                    path.pop();
                    kv.push((field.name.to_string(), field_value))
                }
            }
            if kv.len() != record.fields().len() {
                let missing_fields = record
                    .fields()
                    .filter(|field| !terms.iter().any(|(name, _)| name == field.name))
                    .collect::<Vec<_>>();
                if path.is_empty() {
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
                } else {
                    return Err(Error::Term(Box::new(format!(
                        "Expected {} fields, got {} - missing fields: {} at {:?}",
                        record.fields().len(),
                        kv.len(),
                        missing_fields
                            .iter()
                            .map(|field| field.name)
                            .collect::<Vec<_>>()
                            .join(", "),
                        path.join(".")
                    ))));
                }
            }
            Ok(Val::Record(kv))
        }
        (TermType::Atom, Type::Option(_option_type)) => {
            let none_atom = param_term.atom_to_string()?;
            if none_atom == "none" {
                Ok(Val::Option(None))
            } else {
                Err(Error::Term(Box::new(format!(
                    "Invalid atom: {none_atom}, expected ':none' or '{{:some, term}}' tuple"
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
                path.push("option(some)".to_string());
                let inner_val = term_to_val(second_term, &option_type.ty(), path.clone())?;
                path.pop();
                Ok(Val::Option(Some(Box::new(inner_val))))
            } else {
                Err(Error::Term(Box::new(format!(
                    "Invalid atom: {some_atom}, expected ':some'"
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
                    "Enum value not found: {case_name}"
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
                    "Enum value not found: {case_name}"
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
                    "Invalid atom: {result_kind}, expected ':ok' or ':error' as result"
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
                    path.push("result(ok)".to_string());
                    let ok_val = term_to_val(second_term, &ok_type, path.clone())?;
                    path.pop();
                    Ok(Val::Result(Ok(Some(Box::new(ok_val)))))
                } else {
                    Err(Error::Term(Box::new(
                        "Result-type expected to have an :ok atom, but got 'ok' tuple",
                    )))
                }
            } else if result_kind == "error" {
                if let Some(err_type) = result_type.err() {
                    path.push("result(error)".to_string());
                    let err_val = term_to_val(second_term, &err_type, path.clone())?;
                    path.pop();
                    Ok(Val::Result(Err(Some(Box::new(err_val)))))
                } else {
                    Err(Error::Term(Box::new(
                        "Result-type expected to have an :error atom, but got 'error' tuple",
                    )))
                }
            } else {
                Err(Error::Term(Box::new(format!(
                    "Invalid atom: {result_kind}, expected ':ok' or ':error' as first element in result-tuple"
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
                    "Variant case not found: {case_name}"
                ))))
            }
        }
        (TermType::Binary, Type::Variant(variant_type)) => {
            let case_name = param_term.decode::<String>()?;
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
                    path.push(format!("Variant('{}')", case.name));
                    let payload_val = term_to_val(payload_term, &case_type, path.clone())?;
                    path.pop();
                    Ok(Val::Variant(case_name, Some(Box::new(payload_val))))
                } else {
                    Ok(Val::Variant(case_name, None))
                }
            } else {
                Err(Error::Term(Box::new(format!(
                    "Variant case not found: {case_name}"
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
                        "Flag not found: {flag_name}"
                    ))));
                }
            }

            Ok(Val::Flags(flags))
        }
        (term_type, val_type) => {
            if path.is_empty() {
                Err(Error::Term(Box::new(format!(
                    "Could not convert {term_type:?} to {val_type:?}"
                ))))
            } else {
                Err(Error::Term(Box::new(format!(
                    "Could not convert {:?} to {:?} at {:?}",
                    term_type,
                    val_type,
                    path.join(".")
                ))))
            }
        }
    }
}

/// Convert a Wasm value to an Elixir term.
///
/// Used to for Wasm function calls when passing Wasm params to an Elixir function call.
/// The opposite of this is `term_to_val`, similar to `convert_result_term`.
pub fn val_to_term<'a>(val: &Val, env: rustler::Env<'a>, mut path: Vec<String>) -> Term<'a> {
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
            .enumerate()
            .map(|(index, val)| {
                path.push(format!("list[{index}]"));
                let term = val_to_term(val, env, path.clone());
                path.pop();
                term
            })
            .collect::<Vec<Term<'a>>>()
            .encode(env),
        Val::Record(record) => {
            let converted_pairs = record
                .iter()
                .map(|(key, val)| {
                    path.push(format!("record('{key}')"));
                    let term = (
                        field_name_to_term(&env, key),
                        val_to_term(val, env, path.clone()),
                    );
                    path.pop();
                    term
                })
                .collect::<Vec<(Term, Term)>>();
            Term::map_from_pairs(env, converted_pairs.as_slice()).unwrap()
        }
        Val::Tuple(tuple) => {
            let tuple_terms = tuple
                .iter()
                .enumerate()
                .map(|(index, val)| {
                    path.push(format!("tuple[{index}]"));
                    let term = val_to_term(val, env, path.clone());
                    path.pop();
                    term
                })
                .collect::<Vec<Term<'a>>>();
            make_tuple(env, tuple_terms.as_slice())
        }
        Val::Option(option) => match option {
            Some(boxed_val) => {
                path.push("option(some)".to_string());
                let inner_term = val_to_term(boxed_val, env, path.clone());
                path.pop();
                (atoms::some(), inner_term).encode(env)
            }
            None => atoms::none().encode(env),
        },
        Val::Enum(enum_val) => rustler::serde::atoms::str_to_term(&env, enum_val).unwrap(),
        Val::Result(result) => match result {
            Ok(maybe_val) => {
                if let Some(inner_val) = maybe_val {
                    path.push("result(ok)".to_string());
                    let inner_term = val_to_term(inner_val, env, path.clone());
                    path.pop();
                    (atom::ok(), inner_term).encode(env)
                } else {
                    atom::ok().encode(env)
                }
            }
            Err(maybe_val) => {
                if let Some(inner_val) = maybe_val {
                    path.push("result(error)".to_string());
                    let inner_term = val_to_term(inner_val, env, path.clone());
                    path.pop();
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
                    path.push(format!("Variant('{case_name}')"));
                    let payload_term = val_to_term(boxed_val, env, path.clone());
                    path.pop();
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
        _ => {
            if path.is_empty() {
                String::from("Unsupported type").encode(env)
            } else {
                format!("Unsupported type at {:?}", path.join(".")).encode(env)
            }
        }
    }
}

pub fn vals_to_terms<'a>(vals: &[Val], env: rustler::Env<'a>) -> Vec<Term<'a>> {
    vals.iter()
        .map(|val| val_to_term(val, env, vec![]))
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
        let param = term_to_val(param_term, param_type, vec![])?;
        params.push(param);
    }
    Ok(params)
}

pub fn encode_result<'a>(env: &rustler::Env<'a>, vals: Vec<Val>, from: Term<'a>) -> Term<'a> {
    let result_term = match vals.len() {
        1 => val_to_term(vals.first().unwrap(), *env, vec![]),
        _ => vals
            .iter()
            .map(|term| val_to_term(term, *env, vec![]))
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

/// Convert an Elixir function call result to a Wasm value.
///
/// Used to for Wasm function calls when passing Elixir results back to Wasm.
/// The opposite of this is `term_to_val`, similar to `val_to_term`.
pub fn convert_result_term(
    result_term: Term,
    wit_type: &WitType,
    wit_resolver: &Resolve,
    path: Vec<String>,
) -> Result<Val, (String, Vec<String>)> {
    match wit_type {
        WitType::Bool => Ok(Val::Bool(rustler::types::atom::is_truthy(result_term))),
        WitType::U8 => Ok(Val::U8(
            result_term
                .decode::<u8>()
                .map_err(|_e| ("Expected u8".to_string(), path))?,
        )),
        WitType::U16 => Ok(Val::U16(
            result_term
                .decode::<u16>()
                .map_err(|_e| ("Expected u16".to_string(), path))?,
        )),
        WitType::U32 => Ok(Val::U32(
            result_term
                .decode::<u32>()
                .map_err(|_e| ("Expected u32".to_string(), path))?,
        )),
        WitType::U64 => Ok(Val::U64(
            result_term
                .decode::<u64>()
                .map_err(|_e| ("Expected u64".to_string(), path))?,
        )),
        WitType::S8 => Ok(Val::S8(
            result_term
                .decode::<i8>()
                .map_err(|_e| ("Expected i8".to_string(), path))?,
        )),
        WitType::S16 => Ok(Val::S16(
            result_term
                .decode::<i16>()
                .map_err(|_e| ("Expected i16".to_string(), path))?,
        )),
        WitType::S32 => Ok(Val::S32(
            result_term
                .decode::<i32>()
                .map_err(|_e| ("Expected i32".to_string(), path))?,
        )),
        WitType::S64 => Ok(Val::S64(
            result_term
                .decode::<i64>()
                .map_err(|_e| ("Expected i64".to_string(), path))?,
        )),
        WitType::F32 => Ok(Val::Float32(
            result_term
                .decode::<f32>()
                .map_err(|_e| ("Expected f32".to_string(), path))?,
        )),
        WitType::F64 => Ok(Val::Float64(
            result_term
                .decode::<f64>()
                .map_err(|_e| ("Expected f64".to_string(), path))?,
        )),
        WitType::Char => match result_term.get_type() {
            TermType::Integer => Ok(Val::Char(
                result_term
                    .decode::<u32>()
                    .map_err(|_e| ("Expected a u32".to_string(), path.clone()))?
                    .try_into()
                    .map_err(|_e| ("Could not convert u32 to char".to_string(), path.clone()))?,
            )),
            TermType::Binary => {
                let str = result_term
                    .decode::<String>()
                    .map_err(|_e| ("Expected a string".to_string(), path.clone()))?;
                if let Some(char) = str.chars().next() {
                    Ok(Val::Char(char))
                } else {
                    Err(("Expected a single character".to_string(), path.clone()))
                }
            }
            TermType::List => {
                let list = result_term
                    .decode::<Vec<Term>>()
                    .map_err(|_e| ("Expected alist".to_string(), path.clone()))?;
                if list.len() != 1 {
                    Err(("Expected a single character".to_string(), path.clone()))
                } else {
                    Ok(Val::Char(
                        list[0]
                            .decode::<u32>()
                            .map_err(|_e| ("Expected a u32".to_string(), path.clone()))?
                            .try_into()
                            .map_err(|_e| {
                                ("Could not convert u32 to char".to_string(), path.clone())
                            })?,
                    ))
                }
            }
            _ => Err(("Unsupported type conversion for char".to_string(), path)),
        },
        WitType::String => Ok(Val::String(
            result_term
                .decode::<String>()
                .map_err(|_e| ("Expected a string".to_string(), path))?,
        )),
        WitType::Id(type_id) => {
            let complex_type = &wit_resolver.types[*type_id];
            convert_complex_result(result_term, complex_type, wit_resolver, path)
        }
        _ => Err(("Unsupported type conversion".to_string(), path)),
    }
}

fn convert_complex_result(
    result_term: Term,
    complex_type: &TypeDef,
    wit_resolver: &Resolve,
    mut path: Vec<String>,
) -> Result<Val, (String, Vec<String>)> {
    match &complex_type.kind {
        TypeDefKind::List(list_type) => {
            let decoded_list = result_term
                .decode::<Vec<Term>>()
                .map_err(|_e| ("Expected a list".to_string(), path.clone()))?;
            let list_values = decoded_list
                .iter()
                .enumerate()
                .map(|(index, term)| {
                    path.push(format!("list[{index}]"));
                    let val = convert_result_term(*term, list_type, wit_resolver, path.clone())?;
                    path.pop();
                    Ok(val)
                })
                .collect::<Result<Vec<Val>, (String, Vec<String>)>>()?;
            Ok(Val::List(list_values))
        }
        TypeDefKind::Record(record_type) => {
            let mut record_fields = Vec::with_capacity(record_type.fields.len());
            let decoded_map = result_term
                .decode::<HashMap<Term, Term>>()
                .map_err(|_e| ("Expected a record".to_string(), path.clone()))?;
            let field_term_tuples = decoded_map
                .iter()
                .map(|(key_term, val)| (term_to_field_name(key_term), val))
                .collect::<Vec<(String, &Term)>>();
            for field in &record_type.fields {
                let field_term_option = field_term_tuples.iter().find(|(k, _)| *k == field.name);
                if let Some((field_name, field_term)) = field_term_option {
                    path.push(format!("record('{field_name}')"));
                    let field_value =
                        convert_result_term(**field_term, &field.ty, wit_resolver, path.clone())?;
                    path.pop();
                    record_fields.push((field.name.to_string(), field_value))
                }
            }
            Ok(Val::Record(record_fields))
        }
        TypeDefKind::Tuple(tuple_type) => {
            let tuple_types = tuple_type.types.clone();
            let decoded_tuple = tuple::get_tuple(result_term)
                .map_err(|_e| ("Expected a tuple".to_string(), path.clone()))?;
            let mut tuple_vals: Vec<Val> = Vec::with_capacity(tuple_types.len());
            for (index, (tuple_type, tuple_term)) in
                tuple_types.iter().zip(decoded_tuple).enumerate()
            {
                path.push(format!("tuple[{index}]"));
                let component_val =
                    convert_result_term(tuple_term, tuple_type, wit_resolver, path.clone())?;
                path.pop();
                tuple_vals.push(component_val);
            }
            Ok(Val::Tuple(tuple_vals))
        }
        TypeDefKind::Result(result_type) => {
            if result_term.is_atom() {
                let result_kind = result_term.atom_to_string().map_err(|_e| {
                    path.push("result".to_string());
                    let error = ("Expected a result atom".to_string(), path.clone());
                    path.pop();
                    error
                })?;
                if result_kind == "ok" {
                    if let Some(_ok_type) = result_type.ok {
                        path.push("result(ok)".to_string());
                        let error = Err((
                            "Result-type expected to have an 'ok' tuple, but got :ok atom"
                                .to_string(),
                            path.clone(),
                        ));
                        path.pop();
                        error
                    } else {
                        Ok(Val::Result(Ok(None)))
                    }
                } else if result_kind == "error" {
                    if let Some(_error_type) = result_type.err {
                        path.push("result(error)".to_string());
                        let error = Err((
                            "Result-type expected to have an 'error' tuple, but got :error atom"
                                .to_string(),
                            path.clone(),
                        ));
                        path.pop();
                        error
                    } else {
                        Ok(Val::Result(Err(None)))
                    }
                } else {
                    path.push("result".to_string());
                    let error = Err((
                        format!(
                            "Invalid atom: {result_kind}, expected ':ok' or ':error' as result"
                        ),
                        path.clone(),
                    ));
                    path.pop();
                    error
                }
            } else if result_term.is_tuple() {
                let decoded_tuple = tuple::get_tuple(result_term).map_err(|_e| {
                    path.push("result".to_string());
                    let error = ("Result tuple expected".to_string(), path.clone());
                    path.pop();
                    error
                })?;
                let first_term = decoded_tuple.first().ok_or({
                    path.push("result".to_string());
                    (
                        "Expected result tuple to have 2 elements".to_string(),
                        path.clone(),
                    )
                })?;
                let second_term = decoded_tuple.get(1).ok_or({
                    path.push("result".to_string());
                    (
                        "Expected result tuple to have 2 elements".to_string(),
                        path.clone(),
                    )
                })?;

                let ok_atom = first_term.atom_to_string().map_err(|_e| {
                    path.push("result".to_string());
                    let error = ("Expected a result-tuple atom".to_string(), path.clone());
                    path.pop();
                    error
                })?;
                if ok_atom == "ok" {
                    if let Some(ok_type) = result_type.ok {
                        path.push("result(ok)".to_string());
                        let ok_val = convert_result_term(
                            *second_term,
                            &ok_type,
                            wit_resolver,
                            path.clone(),
                        )?;
                        path.pop();
                        Ok(Val::Result(Ok(Some(Box::new(ok_val)))))
                    } else {
                        Ok(Val::Result(Ok(None)))
                    }
                } else if let Some(err_type) = result_type.err {
                    path.push("result(error)".to_string());
                    let err_val =
                        convert_result_term(*second_term, &err_type, wit_resolver, path.clone())?;
                    path.pop();
                    Ok(Val::Result(Err(Some(Box::new(err_val)))))
                } else {
                    Ok(Val::Result(Err(None)))
                }
            } else {
                path.push("result".to_string());
                let error = Err((
                    "Expected one of: result-tuple, :ok, or :error".to_string(),
                    path.clone(),
                ));
                path.pop();
                error
            }
        }
        TypeDefKind::Option(option_type) => {
            if result_term.is_atom() {
                let none_atom = result_term.atom_to_string().map_err(|_e| {
                    path.push("option".to_string());
                    let error = ("Expected an option atom".to_string(), path.clone());
                    path.pop();
                    error
                })?;
                if none_atom == "none" {
                    Ok(Val::Option(None))
                } else {
                    path.push("option".to_string());
                    let error = Err((
                        format!(
                            "Invalid atom: {none_atom}, expected ':none' or '{{:some, term}}' tuple"
                        ),
                        path.clone(),
                    ));
                    path.pop();
                    error
                }
            } else {
                let decoded_tuple = tuple::get_tuple(result_term).map_err(|_| {
                    path.push("option".to_string());
                    let error = ("Expected an option tuple".to_string(), path.clone());
                    path.pop();
                    error
                })?;
                let first_term = decoded_tuple.first().ok_or({
                    path.push("option".to_string());
                    let error = (
                        "Option-tuple expected to have :some as first element".to_string(),
                        path.clone(),
                    );
                    path.pop();
                    error
                })?;
                let some_atom = first_term.atom_to_string().map_err(|e| {
                    path.push("option".to_string());
                    let error = (
                        format!("Option-tuple expected to have :some as first element - {e:?}"),
                        path.clone(),
                    );
                    path.pop();
                    error
                })?;
                if some_atom != "some" {
                    path.push("option".to_string());
                    let error = Err((
                        format!(
                            "Invalid atom: {some_atom}, expected ':some' as first element in option-tuple"
                        ),
                        path.clone(),
                    ));
                    path.pop();
                    return error;
                }
                let second_term = decoded_tuple.get(1).ok_or({
                    path.push("option".to_string());
                    let error = (
                        "Option-tuple expected to have a second element".to_string(),
                        path.clone(),
                    );
                    path.pop();
                    error
                })?;

                path.push("option(some)".to_string());
                let some_val =
                    convert_result_term(*second_term, option_type, wit_resolver, path.clone())?;
                path.pop();
                Ok(Val::Option(Some(Box::new(some_val))))
            }
        }
        TypeDefKind::Enum(enum_type) => {
            let atom = result_term.atom_to_string().map_err(|_e| {
                path.push("enum".to_string());
                let error = ("Enum expected to be an atom".to_string(), path.clone());
                path.pop();
                error
            })?;
            let enum_val = enum_type.cases.iter().find(|v| v.name == atom);
            if let Some(enum_val) = enum_val {
                Ok(Val::Enum(enum_val.name.clone()))
            } else {
                path.push("enum".to_string());
                let error = Err(("Unknown enum value".to_string(), path.clone()));
                path.pop();
                error
            }
        }
        TypeDefKind::Flags(flags_type) => {
            let decoded_map = result_term.decode::<HashMap<Term, Term>>().map_err(|_e| {
                path.push("flags".to_string());
                let error = ("Expected a flags map".to_string(), path.clone());
                path.pop();
                error
            })?;
            let mut flags = vec![];

            // Convert the map entries to flag names and values
            for (flag_term, value_term) in decoded_map {
                let flag_name = term_to_field_name(&flag_term);

                // Check if the flag exists in the type
                if flags_type.flags.iter().any(|flag| flag.name == flag_name) {
                    let is_set = value_term.decode::<bool>().map_err(|_e| {
                        path.push(format!("flags('{flag_name}')"));
                        let error = (
                            "Expected a bool value in flags map".to_string(),
                            path.clone(),
                        );
                        path.pop();
                        error
                    })?;
                    if is_set {
                        flags.push(flag_name);
                    }
                } else {
                    path.push("flags".to_string());
                    let error = Err((format!("Flag not found: {flag_name}"), path.clone()));
                    path.pop();
                    return error;
                }
            }

            Ok(Val::Flags(flags))
        }
        TypeDefKind::Variant(variant_type) => {
            let case_name = if result_term.is_atom() {
                result_term.atom_to_string().map_err(|_e| {
                    path.push("Variant".to_string());
                    let error = ("Expected a variant atom".to_string(), path.clone());
                    path.pop();
                    error
                })?
            } else if result_term.is_tuple() {
                let decoded_tuple = tuple::get_tuple(result_term).map_err(|_| {
                    path.push("Variant".to_string());
                    let error = ("Expected a variant tuple".to_string(), path.clone());
                    path.pop();
                    error
                })?;
                let first_term = decoded_tuple.first().ok_or({
                    path.push("Variant".to_string());
                    let error = (
                        "Variant-tuple expected to have at least one element".to_string(),
                        path.clone(),
                    );
                    path.pop();
                    error
                })?;
                first_term.atom_to_string().map_err(|_| {
                    path.push("Variant".to_string());
                    let error = (
                        "Variant-tuple expected to have an atom as first element".to_string(),
                        path.clone(),
                    );
                    path.pop();
                    error
                })?
            } else {
                path.push("Variant".to_string());
                let error = Err(("Variant-tuple or atom expected".to_string(), path.clone()));
                path.pop();
                return error;
            };

            let variant_val = variant_type.cases.iter().find(|v| v.name == case_name);
            if let Some(variant_val) = variant_val {
                if let Some(payload_type) = variant_val.ty {
                    let decoded_tuple = tuple::get_tuple(result_term).map_err(|_| {
                        path.push(format!("Variant(:{case_name})"));
                        let error = ("Variant-tuple expected".to_string(), path.clone());
                        path.pop();
                        error
                    })?;
                    let variant_inner_result_term = decoded_tuple.get(1).ok_or_else(|| {
                        path.push(format!("Variant(:{case_name})"));
                        let error = (
                            "Variant-tuple expected to have a second element".to_string(),
                            path.clone(),
                        );
                        path.pop();
                        error
                    })?;
                    path.push(format!("Variant('{case_name}')"));
                    let result = Ok(Val::Variant(
                        variant_val.name.clone(),
                        Some(Box::new(convert_result_term(
                            *variant_inner_result_term,
                            &payload_type,
                            wit_resolver,
                            path.clone(),
                        )?)),
                    ));
                    path.pop();
                    result
                } else {
                    Ok(Val::Variant(variant_val.name.clone(), None))
                }
            } else {
                path.push("Variant".to_string());
                let error = Err((format!("Variant value '{case_name}' not found"), path.clone()));
                path.pop();
                error
            }
        }
        TypeDefKind::Type(wit_type) => {
            convert_result_term(result_term, wit_type, wit_resolver, path)
        }
        _ => {
            path.push("unsupported type".to_string());
            let error = Err(("Unsupported type conversion".to_string(), path.clone()));
            path.pop();
            error
        }
    }
}
