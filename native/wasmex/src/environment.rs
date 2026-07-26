use crate::{
    atoms,
    caller::{handle_command, CallbackSession},
    instance::{map_wasm_values_to_vals, OwnedLinkedModule, WasmValue},
    memory::MemoryResource,
    store::{StoreData, StoreOrCaller, StoreOrCallerResource},
};
use rustler::{
    types::tuple, Atom, Encoder, Error, ListIterator, MapIterator, OwnedEnv, ResourceArc, Term,
};
use std::sync::Mutex;
use wasmtime::{Caller, Engine, Error as WasmtimeError, FuncType, Linker, Val, ValType};

type CallbackResultSender = tokio::sync::oneshot::Sender<(bool, Vec<WasmValue>)>;

pub struct CallbackTokenResource {
    pub token: CallbackToken,
}

#[rustler::resource_impl()]
impl rustler::Resource for CallbackTokenResource {}

pub struct CallbackToken {
    pub return_types: Vec<ValType>,
    pub return_sender: Mutex<Option<CallbackResultSender>>,
}

pub async fn link_modules(
    linker: &mut Linker<StoreData>,
    mut store: impl wasmtime::AsContextMut<Data = StoreData>,
    linked_modules: Vec<OwnedLinkedModule>,
) -> Result<(), String> {
    for linked_module in linked_modules {
        let module_name = linked_module.name;
        let instance = linker
            .instantiate_async(&mut store, &linked_module.module)
            .await
            .map_err(|e| format!("Could not instantiate linked module: {e}"))?;

        linker
            .instance(&mut store, &module_name, instance)
            .map_err(|error| error.to_string())?;
    }

    Ok(())
}

pub fn link_imports(
    engine: &Engine,
    linker: &mut Linker<StoreData>,
    imports: MapIterator,
    pid: rustler::LocalPid,
) -> Result<(), Error> {
    for (namespace_name, namespace_definition) in imports {
        let namespace_name = namespace_name.decode::<String>()?;
        let definition: MapIterator = namespace_definition.decode()?;

        for (import_name, import) in definition {
            let import_name = import_name.decode::<String>()?;
            link_import(engine, linker, &namespace_name, &import_name, import, pid)?;
        }
    }
    Ok(())
}

fn link_import(
    engine: &Engine,
    linker: &mut Linker<StoreData>,
    namespace_name: &str,
    import_name: &str,
    definition: Term,
    pid: rustler::LocalPid,
) -> Result<(), Error> {
    let import_tuple = tuple::get_tuple(definition)?;

    let import_type = import_tuple
        .first()
        .ok_or(Error::Atom("missing_import_type"))?;
    let import_type =
        Atom::from_term(*import_type).map_err(|_| Error::Atom("import type must be an atom"))?;

    if atoms::__fn__().eq(&import_type) {
        return link_imported_function(
            engine,
            linker,
            namespace_name.to_string(),
            import_name.to_string(),
            definition,
            pid,
        );
    }

    Err(Error::Atom("unknown import type"))
}

// Creates a wrapper function used in a Wasm import object.
//
// The `definition` term must contain a function signature matching the signature of the Wasm import.
// Once the imported function is called during Wasm execution, the following happens:
//
// 1. the rust wrapper we define here is called
// 2. it creates a callback token containing an async result sender
// 3. the rust wrapper sends an :invoke_callback message to elixir containing the token and call params
// 4. the Wasmex module receive that call in elixir-land and executes the actual elixir callback
// 5. after the callback finished execution, return values are send back to Rust via `receive_callback_result`
// 6. `receive_callback_result` sends the return values through the token while
//    the Wasmtime host-function future also services scoped Caller operations.
fn link_imported_function(
    engine: &Engine,
    linker: &mut Linker<StoreData>,
    namespace_name: String,
    import_name: String,
    definition: Term,
    pid: rustler::LocalPid,
) -> Result<(), Error> {
    let import_tuple = tuple::get_tuple(definition)?;

    let param_term = import_tuple
        .get(1)
        .ok_or(Error::Atom("missing_import_params"))?;
    let results_term = import_tuple
        .get(2)
        .ok_or(Error::Atom("missing_import_results"))?;

    let params_signature = param_term
        .decode::<ListIterator>()?
        .map(term_to_arg_type)
        .collect::<Result<Vec<ValType>, _>>()?;

    let results_signature = results_term
        .decode::<ListIterator>()?
        .map(term_to_arg_type)
        .collect::<Result<Vec<ValType>, _>>()?;

    let signature = FuncType::new(engine, params_signature, results_signature.clone());
    linker
        .func_new_async(
            &namespace_name.clone(),
            &import_name.clone(),
            signature,
            move |mut caller: Caller<'_, StoreData>, params: &[Val], results: &mut [Val]| {
                let namespace_name = namespace_name.clone();
                let import_name = import_name.clone();
                let results_signature = results_signature.clone();
                Box::new(async move {
                    let (return_sender, mut return_receiver) = tokio::sync::oneshot::channel();
                    let callback_token = ResourceArc::new(CallbackTokenResource {
                        token: CallbackToken {
                            return_types: results_signature.clone(),
                            return_sender: Mutex::new(Some(return_sender)),
                        },
                    });

                    let memory = caller
                        .get_export("memory")
                        .and_then(|memory| memory.into_memory());

                    let (caller_session, mut caller_commands) =
                        CallbackSession::new(caller.engine().clone());

                    let mut msg_env = OwnedEnv::new();
                    let result = msg_env.send_and_clear(&pid.clone(), |env| {
                        let mut callback_params: Vec<Term> = Vec::with_capacity(params.len());
                        for value in params {
                            callback_params.push(match value {
                                Val::I32(i) => i.encode(env),
                                Val::I64(i) => i.encode(env),
                                Val::F32(i) => f32::from_bits(*i).encode(env),
                                Val::F64(i) => f64::from_bits(*i).encode(env),
                                Val::V128(i) => i.as_u128().encode(env),
                                Val::ExternRef(_) => {
                                    (atoms::error(), "unable_to_convert_extern_ref_type")
                                        .encode(env)
                                }
                                Val::FuncRef(_) => {
                                    (atoms::error(), "unable_to_convert_func_ref_type").encode(env)
                                }
                                Val::AnyRef(_) => {
                                    (atoms::error(), "unable_to_convert_any_ref_type").encode(env)
                                }
                                Val::ExnRef(_) => {
                                    (atoms::error(), "unable_to_convert_exn_ref_type").encode(env)
                                }
                                Val::ContRef(_) => {
                                    (atoms::error(), "unable_to_convert_cont_ref_type").encode(env)
                                }
                            })
                        }
                        // Callback context will contain memory (plus maybe globals, tables etc later).
                        // This will allow Elixir callback to operate on these objects.
                        let callback_context = Term::map_new(env);

                        let memory = memory.map(|memory| {
                            ResourceArc::new(MemoryResource {
                                inner: Mutex::new(memory),
                            })
                        });
                        let callback_context = Term::map_put(
                            callback_context,
                            atoms::memory().encode(env),
                            memory.encode(env),
                        )
                        .unwrap();

                        let caller_resource = ResourceArc::new(StoreOrCallerResource {
                            inner: Mutex::new(StoreOrCaller::Caller(caller_session)),
                        });

                        let callback_context = Term::map_put(
                            callback_context,
                            atoms::caller().encode(env),
                            caller_resource.encode(env),
                        )
                        .unwrap();
                        (
                            atoms::invoke_callback(),
                            namespace_name.clone(),
                            import_name.clone(),
                            callback_context,
                            callback_params,
                            callback_token.clone(),
                        )
                            .encode(env)
                    });

                    result.expect("expect no send error");

                    let result = loop {
                        tokio::select! {
                            result = &mut return_receiver => {
                                break result.map_err(|_| {
                                    WasmtimeError::msg("the Elixir callback result channel closed")
                                })?;
                            }
                            command = caller_commands.recv() => {
                                match command {
                                    Some(command) => handle_command(&mut caller, command).await,
                                    None => {
                                        return Err(WasmtimeError::msg(
                                            "the Elixir callback Caller session closed"
                                        ));
                                    }
                                }
                            }
                        }
                    };

                    match result {
                        (true, return_values) => write_results(results, &return_values),
                        (false, _) => {
                            Err(WasmtimeError::msg("the elixir callback threw an exception"))
                        }
                    }
                })
            },
        )
        .map_err(|err| Error::Term(Box::new(err.to_string())))?;

    Ok(())
}

fn write_results(results: &mut [Val], return_values: &[WasmValue]) -> Result<(), WasmtimeError> {
    results.clone_from_slice(&map_wasm_values_to_vals(return_values));
    Ok(())
}

fn term_to_arg_type(term: Term) -> Result<ValType, Error> {
    match Atom::from_term(term) {
        Ok(atom) => {
            if atoms::i32().eq(&atom) {
                Ok(ValType::I32)
            } else if atoms::i64().eq(&atom) {
                Ok(ValType::I64)
            } else if atoms::f32().eq(&atom) {
                Ok(ValType::F32)
            } else if atoms::f64().eq(&atom) {
                Ok(ValType::F64)
            } else if atoms::v128().eq(&atom) {
                Ok(ValType::V128)
            } else {
                Err(Error::Atom("unknown"))
            }
        }
        Err(_) => Err(Error::Atom("not_an_atom")),
    }
}
