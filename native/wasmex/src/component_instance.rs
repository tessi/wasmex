use std::collections::HashMap;
use std::sync::{Condvar, Mutex};

use once_cell::sync::Lazy;
use rustler::env::SavedTerm;

use std::thread;

use crate::atoms;
use crate::component::ComponentResource;
use crate::store::ComponentStoreData;
use crate::store::ComponentStoreResource;
use convert_case::{Case, Casing};
use wasmtime::component::{Func, Instance, Linker, Val};
use wasmtime::{Caller, Trap};
use wiggle::anyhow::{self, anyhow};

use rustler::types::atom::nil;
use rustler::types::tuple;
use rustler::types::tuple::make_tuple;
use rustler::NifResult;
use rustler::ResourceArc;
use rustler::{Encoder, OwnedEnv};
use rustler::{Error, LocalPid};

use rustler::Term;
use rustler::TermType;

use wasmtime::component::Type;
use wasmtime::Store;

use wasmtime_wasi;
use wasmtime_wasi_http;

use crate::component_type_conversion::{term_to_val, val_to_term, vals_to_terms, term_to_field_name, field_name_to_term};

pub struct ComponentCallbackToken {
    pub continue_signal: Condvar,
    pub return_types: Vec<Type>,
    pub return_values: Mutex<Option<(bool, Vec<Val>)>>,
}

pub struct ComponentCallbackTokenResource {
    pub token: ComponentCallbackToken,
}

#[rustler::resource_impl()]
impl rustler::Resource for ComponentCallbackTokenResource {}

pub struct ComponentInstanceResource {
    pub inner: Mutex<Instance>,
}

#[rustler::resource_impl()]
impl rustler::Resource for ComponentInstanceResource {}

#[rustler::nif(name = "component_instance_new")]
pub fn new_instance(
    store_resource: ResourceArc<ComponentStoreResource>,
    component_resource: ResourceArc<ComponentResource>,
    imports: rustler::Term,
) -> NifResult<ResourceArc<ComponentInstanceResource>> {
    let store: &mut Store<ComponentStoreData> =
        &mut *(store_resource.inner.lock().map_err(|e| {
            rustler::Error::Term(Box::new(format!(
                "Could not unlock store resource as the mutex was poisoned: {e}"
            )))
        })?);

    let component = component_resource.inner.lock().map_err(|e| {
        rustler::Error::Term(Box::new(format!(
            "Could not unlock component resource as the mutex was poisoned: {e}"
        )))
    })?;

    let mut linker = Linker::new(store.engine());
    let _ = wasmtime_wasi::add_to_linker_sync(&mut linker);
    let _ = wasmtime_wasi_http::add_only_http_to_linker_sync(&mut linker);
    // Instantiate the component

    // Handle imports
    let imports_map = imports.decode::<HashMap<String, Term>>()?;
    for (name, implementation) in imports_map {
        link_import(&mut linker, name, implementation)?;
    }

    let instance = linker
        .instantiate(&mut *store, &component)
        .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))?;

    Ok(ResourceArc::new(ComponentInstanceResource {
        inner: Mutex::new(instance),
    }))
}

static GLOBAL_DATA: Lazy<Mutex<HashMap<i32, Caller<ComponentStoreData>>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

// fn set_caller(caller: wasmtime::StoreContextMut<'_, ComponentStoreData>) -> i32 {
//     let mut map = GLOBAL_DATA.lock().unwrap();
//     // TODO: prevent duplicates by throwing the dice again when the id is already known
//     let token = rand::random();
//     let caller = unsafe {
//         std::mem::transmute::<Caller<'_, ComponentStoreData>, Caller<'static, ComponentStoreData>>(
//             caller,
//         )
//     };
//     map.insert(token, caller);
//     token
// }

fn link_import(
    linker: &mut Linker<ComponentStoreData>,
    name: String,
    implementation: Term,
) -> NifResult<()> {
    let pid = implementation.get_env().pid();

    println!("linking import {:?}", name);
    linker
        .root()
        .func_new(
            &name.clone(),
            move |mut _store: wasmtime::StoreContextMut<'_, ComponentStoreData>,
                  params,
                  result_values|
                  -> Result<(), anyhow::Error> {
                let mut msg_env = OwnedEnv::new();

                let callback_token = ResourceArc::new(ComponentCallbackTokenResource {
                    token: ComponentCallbackToken {
                        continue_signal: Condvar::new(),
                        return_types: Vec::new(), // We'll need to get these from the interface
                        return_values: Mutex::new(None),
                    },
                });

                let params = params.to_vec();
                let name = name.clone();
                let result = msg_env.send_and_clear(&pid.clone(), |env| {
                    let param_terms = vals_to_terms(&params, env);

                    // Convert component values to Elixir terms
                    // Send message to Elixir process to invoke callback
                    let msg = (
                        atoms::invoke_callback(),
                        name.clone(),
                        callback_token.clone(),
                        param_terms,
                    );
                    // println!("sending msg {:?}", msg);
                    msg
                });
                // });

                // Wait for result
                let mut result = callback_token.token.return_values.lock().unwrap();
                while result.is_none() {
                    result = callback_token.token.continue_signal.wait(result).unwrap();
                }
                let (success, returned_values) = result.take().unwrap();
                if !success {
                    return Err(anyhow::anyhow!("Callback failed"));
                }
                result_values[0] = returned_values[0].clone();
                Ok(())
            },
        )
        .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))?;

    Ok(())
}

// fn encode_callback_results(result_terms: Vec<Term>, result_values: &mut [Val], env: &rustler::Env) -> () {
//   for (result_term, result_value) in result_terms.iter().zip(result_values.iter_mut()) {
//     *result_value = term_to_val(result_term, Type::String)?;
//   }
// }

#[rustler::nif(name = "component_call_function", schedule = "DirtyCpu")]
pub fn call_exported_function(
    env: rustler::Env,
    component_store_resource: ResourceArc<ComponentStoreResource>,
    instance_resource: ResourceArc<ComponentInstanceResource>,
    function_name: String,
    given_params: Term,
    from: Term,
) -> rustler::Atom {
    let pid = env.pid();
    // create erlang environment for the thread
    let mut thread_env = OwnedEnv::new();
    // copy over params into the thread environment
    let function_params = thread_env.save(given_params);
    let from = thread_env.save(from);

    thread::spawn(move || {
        thread_env.send_and_clear(&pid, |thread_env| {
            component_execute_function(
                thread_env,
                component_store_resource,
                instance_resource,
                function_name,
                function_params,
                from,
            )
        })
    });

    atoms::ok()
}

pub fn component_execute_function<'a>(
    thread_env: rustler::Env<'a>,
    component_store_resource: ResourceArc<ComponentStoreResource>,
    instance_resource: ResourceArc<ComponentInstanceResource>,
    func_name: String,
    function_params: SavedTerm,
    from: SavedTerm,
) -> Term<'a> {
    let component_store: &mut Store<ComponentStoreData> =
        &mut *(component_store_resource.inner.lock().unwrap());
    let instance = &mut instance_resource.inner.lock().unwrap();

    let from = from
        .load(thread_env)
        .decode::<Term>()
        .unwrap_or_else(|_| "could not load 'from' param".encode(thread_env));
    let given_params = match function_params.load(thread_env).decode::<Vec<Term>>() {
        Ok(vec) => vec,
        Err(_) => return make_error_tuple(&thread_env, "could not load 'function params'", from),
    };

    let function_result = instance.get_func(&mut *component_store, func_name.clone());
    let function = match function_result {
        Some(func) => func,
        None => {
            return make_error_tuple(
                &thread_env,
                &format!("exported function `{func_name}` not found"),
                from,
            )
        }
    };

    let param_types = function.params(&mut *component_store);
    let converted_params = match convert_params(&param_types, given_params) {
        Ok(params) => params,
        Err(e) => {
            let reason = format!("Error converting param: {e:?}");
            return make_error_tuple(&thread_env, &reason, from);
        }
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
            encode_result(&thread_env, result, from)
        }
        Err(err) => {
            let reason = format!("{err}");
            if let Ok(trap) = err.downcast::<Trap>() {
                return make_error_tuple(
                    &thread_env,
                    &format!("Error during function excecution ({trap}): {reason}"),
                    from,
                );
            } else {
                return make_error_tuple(
                    &thread_env,
                    &format!("Error during function excecution: {reason}"),
                    from,
                );
            }
        }
    }
}

fn make_error_tuple<'a>(env: &rustler::Env<'a>, reason: &str, from: Term<'a>) -> Term<'a> {
    make_tuple(
        *env,
        &[
            atoms::returned_function_call().encode(*env),
            env.error_tuple(reason),
            from,
        ],
    )
}

fn convert_params(param_types: &[Type], param_terms: Vec<Term>) -> Result<Vec<Val>, Error> {
    let mut params = Vec::with_capacity(param_types.len());

    for (param_term, param_type) in param_terms.iter().zip(param_types.iter()) {
        let param = term_to_val(param_term, param_type)?;
        params.push(param);
    }
    Ok(params)
}

fn encode_result<'a>(env: &rustler::Env<'a>, vals: Vec<Val>, from: Term<'a>) -> Term<'a> {
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

#[rustler::nif(name = "component_receive_callback_result")]
pub fn receive_callback_result(
    token_resource: ResourceArc<ComponentCallbackTokenResource>,
    success: bool,
    result: Term,
) -> NifResult<rustler::Atom> {
    println!("receive_callback_result {:?}", result);

    let mut return_values = token_resource.token.return_values.lock().unwrap();
    *return_values = Some((success, vec![term_to_val(&result, &Type::String)?]));
    token_resource.token.continue_signal.notify_one();

    Ok(atoms::ok())
}
