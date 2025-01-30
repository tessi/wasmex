use std::collections::HashMap;
use std::sync::{Condvar, Mutex};

use rustler::env::SavedTerm;
use wit_parser::{Function, Resolve, WorldItem};

use std::thread;

use crate::atoms;
use crate::component::ComponentResource;
use crate::store::ComponentStoreData;
use crate::store::ComponentStoreResource;
use rustler::types::tuple::make_tuple;
use rustler::NifResult;
use rustler::ResourceArc;
use rustler::{Encoder, OwnedEnv};
use rustler::{Error, LocalPid};
use wasmtime::component::{Instance, Linker, Type, Val};
use wasmtime::Trap;
use wiggle::anyhow::{self, anyhow};

use rustler::Term;

use wasmtime::Store;

use wasmtime_wasi;
use wasmtime_wasi_http;

use crate::component_type_conversion::{
    convert_params, convert_result_term, encode_result, vals_to_terms,
};

pub struct ComponentCallbackToken {
    pub continue_signal: Condvar,
    pub name: String,
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
    if store.data().http.is_some() {
        let _ = wasmtime_wasi_http::add_only_http_to_linker_sync(&mut linker);
    }

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

fn create_callback_token(name: String) -> ResourceArc<ComponentCallbackTokenResource> {
    ResourceArc::new(ComponentCallbackTokenResource {
        token: ComponentCallbackToken {
            continue_signal: Condvar::new(),
            name,
            return_values: Mutex::new(None),
        },
    })
}

fn call_elixir_import(
    name: String,
    params: &[Val],
    result_values: &mut [Val],
    pid: LocalPid,
) -> Result<(), anyhow::Error> {
    let mut msg_env = OwnedEnv::new();
    let callback_token = create_callback_token(name.clone());

    let _ = msg_env.send_and_clear(&pid, |env| {
        let param_terms = vals_to_terms(params, env);
        (
            atoms::invoke_callback(),
            name,
            callback_token.clone(),
            param_terms,
        )
    });

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
}

fn link_import(
    linker: &mut Linker<ComponentStoreData>,
    name: String,
    implementation: Term,
) -> NifResult<()> {
    let pid = implementation.get_env().pid();
    let name_for_closure = name.clone();

    linker
        .root()
        .func_new(&name, move |_store, params, result_values| {
            call_elixir_import(name_for_closure.clone(), params, result_values, pid)
        })
        .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))
}

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

fn component_execute_function(
    thread_env: rustler::Env,
    component_store_resource: ResourceArc<ComponentStoreResource>,
    instance_resource: ResourceArc<ComponentInstanceResource>,
    func_name: String,
    function_params: SavedTerm,
    from: SavedTerm,
) -> Term {
    let component_store: &mut Store<ComponentStoreData> =
        &mut (component_store_resource.inner.lock().unwrap());
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
                format!("exported function `{func_name}` not found"),
                from,
            )
        }
    };

    let param_types = function.params(&mut *component_store);
    let param_types = param_types
        .as_ref()
        .iter()
        .map(|x| x.1.clone())
        .collect::<Vec<Type>>();

    let converted_params = match convert_params(param_types.as_ref(), given_params) {
        Ok(params) => params,
        Err(Error::Term(e)) => {
            return make_error_tuple(&thread_env, e.encode(thread_env), from);
        }
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
                make_raise_tuple(
                    &thread_env,
                    format!("Error during function excecution ({trap}): {reason}"),
                    from,
                )
            } else {
                make_raise_tuple(
                    &thread_env,
                    format!("Error during function excecution: {reason}"),
                    from,
                )
            }
        }
    }
}

fn make_error_tuple<'a>(env: &rustler::Env<'a>, reason: impl Encoder, from: Term<'a>) -> Term<'a> {
    make_tuple(
        *env,
        &[
            atoms::returned_function_call().encode(*env),
            env.error_tuple(reason),
            from,
        ],
    )
}

fn make_raise_tuple<'a>(env: &rustler::Env<'a>, reason: impl Encoder, from: Term<'a>) -> Term<'a> {
    make_tuple(
        *env,
        &[
            atoms::returned_function_call().encode(*env),
            make_tuple(*env, &[atoms::raise().encode(*env), reason.encode(*env)]),
            from,
        ],
    )
}

#[rustler::nif(name = "component_receive_callback_result")]
pub fn receive_callback_result(
    component_resource: ResourceArc<ComponentResource>,
    token_resource: ResourceArc<ComponentCallbackTokenResource>,
    _success: bool,
    result: Term,
) -> NifResult<rustler::Atom> {
    let parsed_component = &component_resource.parsed;
    let world = &parsed_component.resolve.worlds[parsed_component.world_id];

    let name = &token_resource.token.name;
    // Find the matching import in the world's imports
    let import_function = world
        .imports
        .iter()
        .filter_map(|(_, item)| match item {
            WorldItem::Function(function) => Some(function),
            _ => None,
        })
        .find(|f| f.item_name() == name)
        .ok_or_else(|| Error::Term(Box::new(format!("Could not find import function {}", name))))?;

    let return_values = token_resource
        .token
        .return_values
        .lock()
        .map_err(|e| Error::Term(Box::new(format!("Failed to lock return values: {}", e))))?;

    populate_return_values(
        &component_resource.parsed.resolve,
        import_function,
        return_values,
        result,
    )
    .map_err(|e| Error::Term(Box::new(format!("Failed to populate return values: {}", e))))?;

    token_resource.token.continue_signal.notify_one();

    Ok(atoms::ok())
}

fn populate_return_values(
    wit_resolver: &Resolve,
    function: &Function,
    mut return_values: std::sync::MutexGuard<'_, Option<(bool, Vec<Val>)>>,
    result: Term,
) -> Result<(), anyhow::Error> {
    // Initialize an empty vector for the return values
    let mut vals = Vec::new();

    // Get the result types from the function
    let results = &function.results;

    let wit_type = match results {
        wit_parser::Results::Anon(wit_type) => wit_type,
        wit_parser::Results::Named(_vec) => {
            return Err(anyhow!("Named return values not supported"))
        }
    };

    if results.len() != 1 {
        return Err(anyhow!(
            "Expected exactly one result type, found {}",
            results.len()
        ));
    }

    vals.push(
        convert_result_term(result, wit_type, wit_resolver)
            .map_err(|e| anyhow!("Failed to convert term: {:?}", e))?,
    );

    // Set the return values
    *return_values = Some((true, vals));

    Ok(())
}
