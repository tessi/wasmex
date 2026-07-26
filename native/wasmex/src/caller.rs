use tokio::sync::mpsc;
use wasmtime::{Caller, Engine, Instance, Memory, Trap, Val, ValType};

use crate::{
    async_reply::{send_saved_term, AsyncReply},
    functions,
    instance::{decode_function_param_terms, map_wasm_values_to_vals},
    instance::{decode_term_as_wasm_value, send_global_value},
    memory::{memory_from_instance, MemoryResource},
    printable_term_type::PrintableTermType,
    store::StoreData,
};
use rustler::{env::SavedTerm, types::tuple::make_tuple, Encoder, OwnedEnv, ResourceArc, Term};
use std::sync::Mutex;

pub enum CallerCommand {
    GetFuel {
        reply: AsyncReply,
    },
    SetFuel {
        fuel: u64,
        reply: AsyncReply,
    },
    MemoryFromInstance {
        instance: Instance,
        reply: AsyncReply,
    },
    MemorySize {
        memory: Memory,
        reply: AsyncReply,
    },
    MemoryGetByte {
        memory: Memory,
        index: usize,
        reply: AsyncReply,
    },
    MemorySetByte {
        memory: Memory,
        index: usize,
        value: u8,
        reply: AsyncReply,
    },
    MemoryRead {
        memory: Memory,
        index: usize,
        len: usize,
        reply: AsyncReply,
    },
    MemoryWrite {
        memory: Memory,
        index: usize,
        bytes: Vec<u8>,
        reply: AsyncReply,
    },
    CallExported {
        instance: Instance,
        function_name: String,
        env: OwnedEnv,
        params: SavedTerm,
        from: SavedTerm,
    },
    NewInstance {
        module: wasmtime::Module,
        linked_modules: Vec<crate::instance::OwnedLinkedModule>,
        callback_pid: rustler::LocalPid,
        env: OwnedEnv,
        imports: SavedTerm,
        reply: AsyncReply,
    },
    GetGlobal {
        instance: Instance,
        name: String,
        reply: AsyncReply,
    },
    SetGlobal {
        instance: Instance,
        name: String,
        env: OwnedEnv,
        value: SavedTerm,
        reply: AsyncReply,
    },
    FunctionExists {
        instance: Instance,
        name: String,
        reply: AsyncReply,
    },
}

#[derive(Clone)]
pub struct CallbackSession {
    sender: mpsc::UnboundedSender<CallerCommand>,
    engine: Engine,
}

impl CallbackSession {
    pub fn new(engine: Engine) -> (Self, mpsc::UnboundedReceiver<CallerCommand>) {
        let (sender, receiver) = mpsc::unbounded_channel();
        (Self { sender, engine }, receiver)
    }

    pub fn engine(&self) -> &Engine {
        &self.engine
    }

    pub fn submit(&self, command: CallerCommand) -> Result<(), CallerCommand> {
        self.sender.send(command).map_err(|error| error.0)
    }
}

pub async fn handle_command(caller: &mut Caller<'_, StoreData>, command: CallerCommand) {
    match command {
        CallerCommand::GetFuel { reply } => match caller.get_fuel() {
            Ok(fuel) => reply.send(fuel),
            Err(error) => reply.send_error(format!("Could not get fuel: {error}")),
        },
        CallerCommand::SetFuel { fuel, reply } => match caller.set_fuel(fuel) {
            Ok(()) => reply.send(()),
            Err(error) => reply.send_error(format!("Could not set fuel: {error}")),
        },
        CallerCommand::MemoryFromInstance { instance, reply } => {
            match memory_from_instance(&instance, &mut *caller) {
                Ok(memory) => reply.send(ResourceArc::new(MemoryResource {
                    inner: Mutex::new(memory),
                })),
                Err(error) => reply.send_error(error),
            }
        }
        CallerCommand::MemorySize { memory, reply } => {
            reply.send(memory.data_size(&*caller));
        }
        CallerCommand::MemoryGetByte {
            memory,
            index,
            reply,
        } => {
            let mut buffer = [0];
            match memory.read(&*caller, index, &mut buffer) {
                Ok(()) => reply.send(buffer[0]),
                Err(error) => reply.send_error(error.to_string()),
            }
        }
        CallerCommand::MemorySetByte {
            memory,
            index,
            value,
            reply,
        } => match memory.write(&mut *caller, index, &[value]) {
            Ok(()) => reply.send(crate::atoms::ok()),
            Err(error) => reply.send_error(error.to_string()),
        },
        CallerCommand::MemoryRead {
            memory,
            index,
            len,
            reply,
        } => {
            let mut buffer = vec![0; len];
            match memory.read(&*caller, index, &mut buffer) {
                Ok(()) => reply.send_binary(buffer),
                Err(error) => reply.send_error(error.to_string()),
            }
        }
        CallerCommand::MemoryWrite {
            memory,
            index,
            bytes,
            reply,
        } => match memory.write(&mut *caller, index, &bytes) {
            Ok(()) => reply.send(crate::atoms::ok()),
            Err(error) => reply.send_error(error.to_string()),
        },
        CallerCommand::CallExported {
            instance,
            function_name,
            env,
            params,
            from,
        } => {
            let prepared = env.run(|term_env| {
                let given_params = params
                    .load(term_env)
                    .decode::<Vec<Term>>()
                    .map_err(|_| "could not load 'function params'".to_string())?;
                let function = functions::find(&instance, &mut *caller, &function_name)
                    .ok_or_else(|| format!("exported function `{function_name}` not found"))?;
                let params = decode_function_param_terms(
                    &function.ty(&*caller).params().collect::<Vec<ValType>>(),
                    given_params,
                )
                .map(|values| map_wasm_values_to_vals(&values))?;
                let result_count = function.ty(&*caller).results().len();
                Ok::<_, String>((function, params, result_count))
            });

            let result = match prepared {
                Ok((function, params, result_count)) => {
                    let mut results = vec![Val::null_extern_ref(); result_count];
                    match function
                        .call_async(&mut *caller, params.as_slice(), &mut results)
                        .await
                    {
                        Ok(()) => env.run(|term_env| {
                            let values = results
                                .into_iter()
                                .map(|value| encode_core_value(term_env, value))
                                .collect::<Result<Vec<_>, _>>();
                            match values {
                                Ok(values) => make_tuple(
                                    term_env,
                                    &[crate::atoms::ok().encode(term_env), values.encode(term_env)],
                                )
                                .encode(term_env),
                                Err(reason) => term_env.error_tuple(reason).encode(term_env),
                            }
                        }),
                        Err(error) => env.run(|term_env| {
                            let reason = format!("{error}");
                            if let Ok(trap) = error.downcast::<Trap>() {
                                term_env
                                    .error_tuple(format!(
                                        "Error during function excecution ({trap}): {reason}"
                                    ))
                                    .encode(term_env)
                            } else {
                                term_env
                                    .error_tuple(format!(
                                        "Error during function excecution: {reason}"
                                    ))
                                    .encode(term_env)
                            }
                        }),
                    }
                }
                Err(reason) => env.run(|term_env| term_env.error_tuple(reason).encode(term_env)),
            };
            let result = env.save(result);
            send_saved_term(env, from, result);
        }
        CallerCommand::NewInstance {
            module,
            linked_modules,
            callback_pid,
            env,
            imports,
            reply,
        } => match crate::instance::instantiate(
            &mut *caller,
            module,
            linked_modules,
            callback_pid,
            env,
            imports,
        )
        .await
        {
            Ok(instance) => reply.send(instance),
            Err(error) => reply.send_error(error),
        },
        CallerCommand::GetGlobal {
            instance,
            name,
            reply,
        } => match instance
            .get_global(&mut *caller, &name)
            .ok_or_else(|| format!("exported global `{name}` not found"))
            .map(|global| global.get(&mut *caller))
        {
            Ok(value) => send_global_value(reply, value),
            Err(error) => reply.send_error(error),
        },
        CallerCommand::SetGlobal {
            instance,
            name,
            env,
            value,
            reply,
        } => {
            let result = env.run(|term_env| {
                let term = value.load(term_env);
                let global = instance
                    .get_global(&mut *caller, &name)
                    .ok_or_else(|| format!("exported global `{name}` not found"))?;
                let global_type = global.ty(&*caller).content().clone();
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
                    .set(&mut *caller, value)
                    .map_err(|error| format!("Could not set global: {error}"))
            });
            match result {
                Ok(()) => reply.send(()),
                Err(error) => reply.send_error(error),
            }
        }
        CallerCommand::FunctionExists {
            instance,
            name,
            reply,
        } => reply.send(functions::exists(&instance, &mut *caller, &name)),
    }
}

fn encode_core_value<'a>(env: rustler::Env<'a>, value: Val) -> Result<Term<'a>, &'static str> {
    match value {
        Val::I32(value) => Ok(value.encode(env)),
        Val::I64(value) => Ok(value.encode(env)),
        Val::F32(value) => Ok(f32::from_bits(value).encode(env)),
        Val::F64(value) => Ok(f64::from_bits(value).encode(env)),
        Val::V128(value) => Ok(rustler::BigInt::from(value.as_u128()).encode(env)),
        Val::FuncRef(_) => Err("unable_to_return_func_ref_type"),
        Val::ExternRef(_) => Err("unable_to_return_extern_ref_type"),
        Val::AnyRef(_) => Err("unable_to_return_any_ref_type"),
        Val::ExnRef(_) => Err("unable_to_return_exn_ref_type"),
        Val::ContRef(_) => Err("unable_to_return_cont_ref_type"),
    }
}
