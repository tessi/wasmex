// Clippy regression in rust 1.80.0
// see: https://github.com/rust-lang/rust-clippy/issues/13170
#![allow(clippy::needless_borrows_for_generic_args)]

use crate::{
    async_reply::{send_saved_term, submit_error, AsyncReply},
    atoms,
    environment::{link_imports, link_modules, CallbackTokenResource},
    functions,
    module::ModuleResource,
    printable_term_type::PrintableTermType,
    store::{StoreData, StoreOrCallerResource, StoreTarget},
};
use rustler::{
    env::SavedTerm,
    types::{tuple::make_tuple, ListIterator},
    Encoder, Env, Error, MapIterator, NifMap, NifResult, OwnedEnv, ResourceArc, Term, TermType,
};
use std::ops::Deref;
use std::sync::Mutex;
use wasmtime::{Instance, Linker, Module, Trap, Val, ValType};

#[derive(NifMap)]
pub struct LinkedModule {
    pub name: String,
    pub module_resource: ResourceArc<ModuleResource>,
}

pub struct OwnedLinkedModule {
    pub name: String,
    pub module: Module,
}

pub struct InstanceResource {
    pub inner: Mutex<Instance>,
}

#[rustler::resource_impl()]
impl rustler::Resource for InstanceResource {}

// creates a new instance from the given Wasm bytes
// expects the following elixir params
//
// * store (StoreResource): the store the module was compiled with
// * module (ModuleResource): the compiled Wasm module
// * imports (map): a map defining eventual instance imports, may be empty if there are none.
//   structure: %{namespace_name: %{import_name: {:fn, param_types, result_types, captured_function}}}
#[rustler::nif(name = "instance_new")]
pub fn new(
    store_or_caller_resource: ResourceArc<StoreOrCallerResource>,
    module_resource: ResourceArc<ModuleResource>,
    imports: Term,
    linked_modules: Vec<LinkedModule>,
    from: Term,
) -> Result<rustler::Atom, rustler::Error> {
    let module = module_resource
        .inner
        .lock()
        .map_err(|e| {
            rustler::Error::Term(Box::new(format!(
                "Could not unlock module resource as the mutex was poisoned: {e}"
            )))
        })?
        .clone();
    let linked_modules = linked_modules
        .into_iter()
        .map(|linked_module| {
            let module = linked_module
                .module_resource
                .inner
                .lock()
                .map_err(|error| {
                    rustler::Error::Term(Box::new(format!(
                        "Could not unlock linked module resource: {error}"
                    )))
                })?
                .clone();
            Ok(OwnedLinkedModule {
                name: linked_module.name,
                module,
            })
        })
        .collect::<Result<Vec<_>, rustler::Error>>()?;

    let callback_pid = imports.get_env().pid();
    let term_env = OwnedEnv::new();
    let imports = term_env.save(imports);
    let reply = AsyncReply::new(from);

    match store_or_caller_resource.target()? {
        StoreTarget::Executor(executor) => {
            let submit_reply = AsyncReply::new(from);
            if let Err(error) = executor.submit(move |mut store| async move {
                match instantiate(
                    &mut store,
                    module,
                    linked_modules,
                    callback_pid,
                    term_env,
                    imports,
                )
                .await
                {
                    Ok(instance) => reply.send(instance),
                    Err(error) => reply.send_error(error),
                }
                store
            }) {
                submit_error(submit_reply, error);
            }
        }
        StoreTarget::Caller(session) => {
            let command = crate::caller::CallerCommand::NewInstance {
                module,
                linked_modules,
                callback_pid,
                env: term_env,
                imports,
                reply,
            };
            if let Err(crate::caller::CallerCommand::NewInstance { reply, .. }) =
                session.submit(command)
            {
                reply.send_error("Caller is no longer valid");
            }
        }
    }

    Ok(atoms::ok())
}

pub(crate) async fn instantiate(
    mut store: impl wasmtime::AsContextMut<Data = StoreData>,
    module: Module,
    linked_modules: Vec<OwnedLinkedModule>,
    callback_pid: rustler::LocalPid,
    term_env: OwnedEnv,
    imports: SavedTerm,
) -> Result<ResourceArc<InstanceResource>, String> {
    let mut linker = term_env
        .run(|env| {
            let imports = imports.load(env).decode::<MapIterator>()?;
            create_linker(&store, imports, callback_pid)
        })
        .map_err(|error| format!("{error:?}"))?;

    link_modules(&mut linker, &mut store, linked_modules)
        .await
        .map_err(|error| format!("{error:?}"))?;
    linker
        .instantiate_async(&mut store, &module)
        .await
        .map(|instance| {
            ResourceArc::new(InstanceResource {
                inner: Mutex::new(instance),
            })
        })
        .map_err(|error| error.to_string())
}

fn create_linker(
    store: impl wasmtime::AsContext<Data = StoreData>,
    imports: MapIterator,
    callback_pid: rustler::LocalPid,
) -> Result<Linker<StoreData>, Error> {
    let store = store.as_context();
    let mut linker = Linker::new(store.engine());
    if store.data().wasi.is_some() {
        linker.allow_shadowing(true);
        wasmtime_wasi::p1::add_to_linker_async(&mut linker, |s: &mut StoreData| {
            s.wasi.as_mut().unwrap()
        })
        .map_err(|err| Error::Term(Box::new(err.to_string())))?;
    }

    link_imports(store.engine(), &mut linker, imports, callback_pid)?;
    Ok(linker)
}

#[rustler::nif(name = "instance_get_global_value")]
pub fn get_global_value(
    store_or_caller_resource: ResourceArc<StoreOrCallerResource>,
    instance_resource: ResourceArc<InstanceResource>,
    global_name: String,
    from: Term,
) -> NifResult<rustler::Atom> {
    let instance: Instance = *(instance_resource.inner.lock().map_err(|e| {
        rustler::Error::Term(Box::new(format!(
            "Could not unlock instance resource as the mutex was poisoned: {e}"
        )))
    })?);
    let reply = AsyncReply::new(from);

    match store_or_caller_resource.target()? {
        StoreTarget::Executor(executor) => {
            let submit_reply = AsyncReply::new(from);
            if let Err(error) = executor.submit(move |mut store| async move {
                match instance
                    .get_global(&mut store, &global_name)
                    .ok_or_else(|| format!("exported global `{global_name}` not found"))
                    .map(|global| global.get(&mut store))
                {
                    Ok(value) => send_global_value(reply, value),
                    Err(error) => reply.send_error(error),
                }
                store
            }) {
                submit_error(submit_reply, error);
            }
        }
        StoreTarget::Caller(session) => {
            let command = crate::caller::CallerCommand::GetGlobal {
                instance,
                name: global_name,
                reply,
            };
            if let Err(crate::caller::CallerCommand::GetGlobal { reply, .. }) =
                session.submit(command)
            {
                reply.send_error("Caller is no longer valid");
            }
        }
    }
    Ok(atoms::ok())
}

#[rustler::nif(name = "instance_set_global_value")]
pub fn set_global_value(
    store_or_caller_resource: ResourceArc<StoreOrCallerResource>,
    instance_resource: ResourceArc<InstanceResource>,
    global_name: String,
    new_value: Term,
    from: Term,
) -> NifResult<rustler::Atom> {
    let instance: Instance = *(instance_resource.inner.lock().map_err(|e| {
        rustler::Error::Term(Box::new(format!(
            "Could not unlock instance resource as the mutex was poisoned: {e}"
        )))
    })?);
    let term_env = OwnedEnv::new();
    let new_value = term_env.save(new_value);
    let reply = AsyncReply::new(from);

    match store_or_caller_resource.target()? {
        StoreTarget::Executor(executor) => {
            let submit_reply = AsyncReply::new(from);
            if let Err(error) = executor.submit(move |mut store| async move {
                let result = term_env.run(|env| {
                    let term = new_value.load(env);
                    let global = instance
                        .get_global(&mut store, &global_name)
                        .ok_or_else(|| format!("exported global `{global_name}` not found"))?;
                    let global_type = global.ty(&store).content().clone();
                    let value =
                        decode_term_as_wasm_value(global_type.clone(), term).ok_or_else(|| {
                            format!(
                                "Cannot convert to a WebAssembly {:?} value. Given `{:?}`.",
                                global_type,
                                PrintableTermType::PrintTerm(term.get_type())
                            )
                        })?;
                    let value = map_wasm_values_to_vals(&[value]).remove(0);
                    global
                        .set(&mut store, value)
                        .map_err(|error| format!("Could not set global: {error}"))
                });
                match result {
                    Ok(()) => reply.send(()),
                    Err(error) => reply.send_error(error),
                }
                store
            }) {
                submit_error(submit_reply, error);
            }
        }
        StoreTarget::Caller(session) => {
            let command = crate::caller::CallerCommand::SetGlobal {
                instance,
                name: global_name,
                env: term_env,
                value: new_value,
                reply,
            };
            if let Err(crate::caller::CallerCommand::SetGlobal { reply, .. }) =
                session.submit(command)
            {
                reply.send_error("Caller is no longer valid");
            }
        }
    }
    Ok(atoms::ok())
}

#[rustler::nif(name = "instance_function_export_exists")]
pub fn function_export_exists(
    store_or_caller_resource: ResourceArc<StoreOrCallerResource>,
    instance_resource: ResourceArc<InstanceResource>,
    function_name: String,
    from: Term,
) -> NifResult<rustler::Atom> {
    let instance: Instance = *(instance_resource.inner.lock().map_err(|e| {
        rustler::Error::Term(Box::new(format!(
            "Could not unlock instance resource as the mutex was poisoned: {e}"
        )))
    })?);
    let reply = AsyncReply::new(from);
    match store_or_caller_resource.target()? {
        StoreTarget::Executor(executor) => {
            let submit_reply = AsyncReply::new(from);
            if let Err(error) = executor.submit(move |mut store| async move {
                reply.send(functions::exists(&instance, &mut store, &function_name));
                store
            }) {
                submit_error(submit_reply, error);
            }
        }
        StoreTarget::Caller(session) => {
            let command = crate::caller::CallerCommand::FunctionExists {
                instance,
                name: function_name,
                reply,
            };
            if let Err(crate::caller::CallerCommand::FunctionExists { reply, .. }) =
                session.submit(command)
            {
                reply.send_error("Caller is no longer valid");
            }
        }
    }
    Ok(atoms::ok())
}

pub(crate) fn send_global_value(reply: AsyncReply, value: Val) {
    match value {
        Val::I32(value) => reply.send(value),
        Val::I64(value) => reply.send(value),
        Val::F32(value) => reply.send(f32::from_bits(value)),
        Val::F64(value) => reply.send(f64::from_bits(value)),
        Val::V128(value) => reply.send(rustler::BigInt::from(value.as_u128())),
        Val::FuncRef(_) => reply.send_error("unable_to_return_func_ref_type"),
        Val::ExternRef(_) => reply.send_error("unable_to_return_extern_ref_type"),
        Val::AnyRef(_) => reply.send_error("unable_to_return_any_ref_type"),
        Val::ExnRef(_) => reply.send_error("unable_to_return_exn_ref_type"),
        Val::ContRef(_) => reply.send_error("unable_to_return_cont_ref_type"),
    }
}

#[rustler::nif(name = "instance_call_exported_function")]
pub fn call_exported_function(
    store_or_caller_resource: ResourceArc<StoreOrCallerResource>,
    instance_resource: ResourceArc<InstanceResource>,
    function_name: String,
    params: Term,
    from: Term,
    timeout_ms: Option<u64>,
) -> rustler::Atom {
    let target = match store_or_caller_resource.target() {
        Ok(target) => target,
        Err(error) => {
            AsyncReply::new(from).send_error(format!("{error:?}"));
            return atoms::ok();
        }
    };

    if let StoreTarget::Caller(session) = target {
        let env = OwnedEnv::new();
        let params = env.save(params);
        let saved_from = env.save(from);
        let submit_reply = AsyncReply::new(from);
        let command = crate::caller::CallerCommand::CallExported {
            instance: *instance_resource.inner.lock().unwrap(),
            function_name,
            env,
            params,
            from: saved_from,
        };
        if session.submit(command).is_err() {
            submit_reply.send_error("Caller is no longer valid");
        }
        return atoms::ok();
    }
    let StoreTarget::Executor(executor) = target else {
        unreachable!()
    };

    let deadline = timeout_ms
        .map(|timeout| tokio::time::Instant::now() + std::time::Duration::from_millis(timeout));

    let mut thread_env = OwnedEnv::new();
    let function_params = thread_env.save(params);
    let saved_from = thread_env.save(from);
    let submit_reply = AsyncReply::new(from);

    if let Err(error) = executor.submit(move |mut store| async move {
        let result = execute_function(
            &mut thread_env,
            &mut store,
            instance_resource,
            function_name,
            function_params,
        );
        let result = match deadline {
            Some(deadline) => tokio::time::timeout_at(deadline, result).await.ok(),
            None => Some(result.await),
        };
        if let Some(result) = result {
            send_saved_term(thread_env, saved_from, result);
        }
        store
    }) {
        submit_error(submit_reply, error);
    }

    atoms::ok()
}

async fn execute_function(
    thread_env: &mut OwnedEnv,
    store: &mut wasmtime::Store<StoreData>,
    instance_resource: ResourceArc<InstanceResource>,
    function_name: String,
    function_params: SavedTerm,
) -> SavedTerm {
    let prepared = thread_env.run(|env: Env| {
        let given_params = function_params
            .load(env)
            .decode::<Vec<Term>>()
            .map_err(|_| "could not load 'function params'".to_string())?;
        let instance: Instance = *(instance_resource.deref().inner.lock().unwrap());
        let function = functions::find(&instance, &mut *store, &function_name)
            .ok_or_else(|| format!("exported function `{function_name}` not found"))?;
        let function_params = decode_function_param_terms(
            &function.ty(&*store).params().collect::<Vec<ValType>>(),
            given_params,
        )
        .map(|values| map_wasm_values_to_vals(&values))?;
        let results_count = function.ty(&*store).results().len();
        Ok::<_, String>((function, function_params, results_count))
    });

    let (function, function_params, results_count) = match prepared {
        Ok(prepared) => prepared,
        Err(reason) => {
            let result = thread_env.run(|env| env.error_tuple(reason).encode(env));
            return thread_env.save(result);
        }
    };

    let mut results = vec![Val::null_extern_ref(); results_count];
    let call_result = function
        .call_async(&mut *store, function_params.as_slice(), &mut results)
        .await;

    let result = thread_env.run(|env: Env| {
        match call_result {
            Ok(_) => (),
            Err(err) => {
                let reason = format!("{err}");
                if let Ok(trap) = err.downcast::<Trap>() {
                    return env
                        .error_tuple(format!(
                            "Error during function excecution ({trap}): {reason}"
                        ))
                        .encode(env);
                } else {
                    return env
                        .error_tuple(format!("Error during function excecution: {reason}"))
                        .encode(env);
                }
            }
        };
        let mut return_values: Vec<Term> = Vec::with_capacity(results_count);
        for value in results.iter().cloned() {
            return_values.push(match value {
                Val::I32(i) => i.encode(env),
                Val::I64(i) => i.encode(env),
                Val::F32(i) => f32::from_bits(i).encode(env),
                Val::F64(i) => f64::from_bits(i).encode(env),
                Val::V128(i) => rustler::BigInt::from(i.as_u128()).encode(env),
                Val::FuncRef(_) => {
                    return env
                        .error_tuple("unable_to_return_func_ref_type")
                        .encode(env)
                }
                Val::ExternRef(_) => {
                    return env
                        .error_tuple("unable_to_return_extern_ref_type")
                        .encode(env)
                }
                Val::AnyRef(_) => {
                    return env.error_tuple("unable_to_return_any_ref_type").encode(env)
                }
                Val::ExnRef(_) => {
                    return env.error_tuple("unable_to_return_exn_ref_type").encode(env)
                }
                Val::ContRef(_) => {
                    return env
                        .error_tuple("unable_to_return_cont_ref_type")
                        .encode(env)
                }
            })
        }

        make_tuple(env, &[atoms::ok().encode(env), return_values.encode(env)]).encode(env)
    });
    thread_env.save(result)
}

#[derive(Debug, Copy, Clone)]
pub enum WasmValue {
    I32(i32),
    I64(i64),
    F32(f32),
    F64(f64),
    V128(u128),
}

pub(crate) fn decode_term_as_wasm_value(expected_type: ValType, term: Term) -> Option<WasmValue> {
    let value = match (expected_type, term.get_type()) {
        (ValType::I32, TermType::Integer | TermType::Float) => match term.decode::<i32>() {
            Ok(value) => WasmValue::I32(value),
            Err(_) => return None,
        },
        (ValType::I64, TermType::Integer | TermType::Float) => match term.decode::<i64>() {
            Ok(value) => WasmValue::I64(value),
            Err(_) => return None,
        },
        (ValType::F32, TermType::Integer | TermType::Float) => match term.decode::<f32>() {
            Ok(value) => {
                if value.is_finite() {
                    WasmValue::F32(value)
                } else {
                    return None;
                }
            }
            Err(_) => return None,
        },
        (ValType::F64, TermType::Integer | TermType::Float) => match term.decode::<f64>() {
            Ok(value) => WasmValue::F64(value),
            Err(_) => return None,
        },
        (ValType::V128, TermType::Integer | TermType::Float) => {
            match term.decode::<rustler::BigInt>() {
                Ok(value) => {
                    let (_sign, mut bytes_vec) = value.to_bytes_be();
                    if value < rustler::BigInt::ZERO {
                        return None;
                    }

                    // prepend 0 bytes to make it 16 bytes long. `to_bytes_be()` only returns leading non-zero bytes
                    while bytes_vec.len() < 16 {
                        bytes_vec.insert(0, 0);
                    }
                    let bytes: [u8; 16] = match bytes_vec.len() {
                        16 => {
                            let mut bytes = [0; 16];
                            bytes.copy_from_slice(&bytes_vec);
                            bytes
                        }
                        _ => return None,
                    };
                    WasmValue::V128(u128::from_be_bytes(bytes))
                }
                Err(_) => return None,
            }
        }
        (_val_type, _term_type) => return None,
    };

    Some(value)
}

pub fn decode_function_param_terms(
    params: &[ValType],
    function_param_terms: Vec<Term>,
) -> Result<Vec<WasmValue>, String> {
    if params.len() != function_param_terms.len() {
        return Err(format!(
            "number of params does not match. expected {}, got {}",
            params.len(),
            function_param_terms.len()
        ));
    }

    let mut function_params = Vec::<WasmValue>::with_capacity(params.len());
    for (nth, (param, given_param)) in params.iter().zip(function_param_terms).enumerate() {
        let value = match (
            decode_term_as_wasm_value(param.clone(), given_param),
            given_param.get_type(),
        ) {
            (Some(value), _) => value,
            (_, TermType::Integer | TermType::Float) => {
                return Err(format!(
                    "Cannot convert argument #{} to a WebAssembly {} value.",
                    nth + 1,
                    format!("{param:?}").to_lowercase()
                ))
            }
            (_, term_type) => {
                return Err(format!(
                    "Cannot convert argument #{} to a WebAssembly {:?} value. Given `{:?}`.",
                    nth + 1,
                    param,
                    PrintableTermType::PrintTerm(term_type)
                ));
            }
        };
        function_params.push(value);
    }
    Ok(function_params)
}

pub fn map_wasm_values_to_vals(values: &[WasmValue]) -> Vec<Val> {
    values
        .iter()
        .map(|value| match value {
            WasmValue::I32(value) => (*value).into(),
            WasmValue::I64(value) => (*value).into(),
            WasmValue::F32(value) => (*value).into(),
            WasmValue::F64(value) => (*value).into(),
            WasmValue::V128(value) => (*value).into(),
        })
        .collect()
}

// called from elixir, params
// * callback_token
// * success: :ok | :error
//   indicates whether the call was successful or produced an elixir-error
// * results: [number]
//   return values of the elixir-callback - empty list when success-type is :error
#[rustler::nif(name = "instance_receive_callback_result")]
pub fn receive_callback_result(
    token_resource: ResourceArc<CallbackTokenResource>,
    success: bool,
    result_list: ListIterator,
) -> NifResult<rustler::Atom> {
    let results = if success {
        let return_types = token_resource.token.return_types.clone();
        match decode_function_param_terms(&return_types, result_list.collect()) {
            Ok(v) => v,
            Err(reason) => {
                return Err(Error::Term(Box::new(format!(
                    "could not convert callback result param to expected return signature: {reason}"
                ))));
            }
        }
    } else {
        vec![]
    };

    let sender = token_resource
        .token
        .return_sender
        .lock()
        .map_err(|error| {
            Error::Term(Box::new(format!(
                "Could not unlock callback result sender: {error}"
            )))
        })?
        .take()
        .ok_or_else(|| Error::Term(Box::new("Callback result was already sent")))?;
    sender
        .send((success, results))
        .map_err(|_| Error::Term(Box::new("Callback is no longer waiting for a result")))?;

    Ok(atoms::ok())
}
