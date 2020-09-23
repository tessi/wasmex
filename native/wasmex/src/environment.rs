use std::cell::UnsafeCell;
use std::mem::MaybeUninit;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};

use rustler::{
    resource::ResourceArc, types::tuple, Atom, Encoder, Error, ListIterator, MapIterator, OwnedEnv,
    Term,
};
use wasmer::{
    imports, namespace, Exports, Function, FunctionType, ImportObject, Memory, RuntimeError, Store,
    Type, Val,
};

use crate::{
    atoms,
    instance::{map_to_wasmer_values, RustValue},
    memory::MemoryResource,
};

/// The environment provided to the WASI imports.
#[derive(Clone)]
pub struct Environment {
    memory: Arc<LazilyInitializedMemory>,
}

impl Default for Environment {
    fn default() -> Self {
        Self::new()
    }
}

/// Wrapper type around `Memory` used to delay initialization of the memory.
///
/// The `initialized` field is used to indicate if it's safe to read `memory` as `Memory`.
///
/// The `mutate_lock` is used to prevent access from multiple threads during initialization.
struct LazilyInitializedMemory {
    initialized: AtomicBool,
    memory: UnsafeCell<MaybeUninit<Memory>>,
    mutate_lock: Mutex<()>,
}

impl LazilyInitializedMemory {
    fn new() -> Self {
        Self {
            initialized: AtomicBool::new(false),
            memory: UnsafeCell::new(MaybeUninit::zeroed()),
            mutate_lock: Mutex::new(()),
        }
    }

    /// Initialize the memory, making it safe to read from.
    ///
    /// Returns whether or not the set was successful. If the set failed then
    /// the memory has already been initialized.
    fn set_memory(&self, memory: Memory) -> bool {
        // synchronize it
        let _guard = self.mutate_lock.lock();
        if self.initialized.load(Ordering::Acquire) {
            return false;
        }

        unsafe {
            let ptr = self.memory.get();
            let mem_inner: &mut MaybeUninit<Memory> = &mut *ptr;
            mem_inner.as_mut_ptr().write(memory);
        }
        self.initialized.store(true, Ordering::Release);

        true
    }

    /// Returns `None` if the memory has not been initialized yet.
    /// Otherwise returns the memory that was used to initialize it.
    fn get_memory(&self) -> Option<&Memory> {
        // Based on normal usage, `Relaxed` is fine...
        // TODO: investigate if it's possible to use the API in a way where `Relaxed`
        //       is not fine
        if self.initialized.load(Ordering::Relaxed) {
            unsafe {
                let maybe_mem = self.memory.get();
                Some(&*(*maybe_mem).as_ptr())
            }
        } else {
            None
        }
    }
}

impl Drop for LazilyInitializedMemory {
    fn drop(&mut self) {
        if self.initialized.load(Ordering::Acquire) {
            unsafe {
                // We want to get the internal value in memory, so we need to consume
                // the `UnsafeCell` and assume the `MapbeInit` is initialized, but because
                // we only have a `&mut self` we can't do this directly, so we swap the data
                // out so we can drop it (via `assume_init`).
                let mut maybe_uninit = UnsafeCell::new(MaybeUninit::zeroed());
                std::mem::swap(&mut self.memory, &mut maybe_uninit);
                maybe_uninit.into_inner().assume_init();
            }
        }
    }
}

pub struct CallbackTokenResource {
    pub token: CallbackToken,
}

pub struct CallbackToken {
    pub continue_signal: Condvar,
    pub return_types: Vec<Type>,
    pub return_values: Mutex<Option<(bool, Vec<RustValue>)>>,
}

impl Environment {
    pub fn new() -> Self {
        Self {
            memory: Arc::new(LazilyInitializedMemory::new()),
        }
    }

    pub fn import_object(&mut self, imports: MapIterator) -> Result<ImportObject, Error> {
        let mut object = imports! {};
        for (name, namespace_definition) in imports {
            let name = name.decode::<String>()?;
            let namespace = self.create_namespace(&name, namespace_definition)?;
            object.register(name, namespace);
        }
        Ok(object)
    }

    /// Set the memory
    pub fn set_memory(&mut self, memory: Memory) -> bool {
        self.memory.set_memory(memory)
    }

    /// Get a reference to the memory
    pub fn memory(&self) -> &Memory {
        self.memory.get_memory().expect("The expected Memory is not attached to the `Environment`. Did you forgot to call environment.set_memory(...)?")
    }

    fn create_namespace(&self, name: &str, definition: Term) -> Result<Exports, Error> {
        let mut namespace = namespace!();
        let definition: MapIterator = definition.decode()?;
        for (import_name, import) in definition {
            let import_name = import_name.decode::<String>()?;
            self.create_import(&mut namespace, &name, &import_name, import)?;
        }
        Ok(namespace)
    }

    fn create_import(
        &self,
        namespace: &mut Exports,
        namespace_name: &str,
        import_name: &str,
        definition: Term,
    ) -> Result<(), Error> {
        let import_tuple = tuple::get_tuple(definition)?;

        let import_type = import_tuple
            .get(0)
            .ok_or_else(|| Error::Atom("missing_import_type"))?;
        let import_type = Atom::from_term(*import_type)
            .map_err(|_| Error::Atom("import type must be an atom"))?;

        if atoms::__fn__().eq(&import_type) {
            let import = self.create_imported_function(
                namespace_name.to_string(),
                import_name.to_string(),
                definition,
            )?;
            namespace.insert(import_name, import);
            return Ok(());
        }

        Err(Error::Atom("unknown import type"))
    }

    // Creates a wrapper function used in a WASM import object.
    // The `definition` term must contain a function signature matching the signature if the WASM import.
    // Once the imported function is called during WASM execution, the following happens:
    // 1. the rust wrapper we define here is called
    // 2. it creates a callback token containing a Mutex for storing the call result and a Condvar
    // 3. the rust wrapper sends an :invoke_callback message to elixir containing the token and call params
    // 4. the Wasmex module receive that call in elixir-land and executes the actual elixir callback
    // 5. after the callback finished execution, return values are send back to Rust via `receive_callback_result`
    // 6. `receive_callback_result` saves the return values in the callback tokens mutex and signals the condvar,
    //    so that the original wrapper function can continue code execution
    fn create_imported_function(
        &self,
        namespace_name: String,
        import_name: String,
        definition: Term,
    ) -> Result<Function, Error> {
        let pid = definition.get_env().pid();

        let import_tuple = tuple::get_tuple(definition)?;

        let param_term = import_tuple
            .get(1)
            .ok_or_else(|| Error::Atom("missing_import_params"))?;
        let results_term = import_tuple
            .get(2)
            .ok_or_else(|| Error::Atom("missing_import_results"))?;

        let params_signature = param_term
            .decode::<ListIterator>()?
            .map(term_to_arg_type)
            .collect::<Result<Vec<Type>, _>>()?;

        let results_signature = results_term
            .decode::<ListIterator>()?
            .map(term_to_arg_type)
            .collect::<Result<Vec<Type>, _>>()?;

        let store = Store::default();
        let signature = FunctionType::new(params_signature, results_signature.clone());
        let function = Function::new_with_env(
            &store,
            &signature,
            self.clone(),
            move |ctx, params: &[Val]| -> Result<Vec<Val>, RuntimeError> {
                let callback_token = ResourceArc::new(CallbackTokenResource {
                    token: CallbackToken {
                        continue_signal: Condvar::new(),
                        return_types: results_signature.clone(),
                        return_values: Mutex::new(None),
                    },
                });

                let mut msg_env = OwnedEnv::new();
                msg_env.send_and_clear(&pid.clone(), |env| {
                    let mut callback_params: Vec<Term> = Vec::with_capacity(params.len());
                    for value in params {
                        callback_params.push(match value {
                            Val::I32(i) => i.encode(env),
                            Val::I64(i) => i.encode(env),
                            Val::F32(i) => i.encode(env),
                            Val::F64(i) => i.encode(env),
                            // encoding V128 is not yet supported by rustler
                            Val::V128(_) => {
                                (atoms::error(), "unable_to_convert_v128_type").encode(env)
                            }
                            Val::ExternRef(_) => {
                                (atoms::error(), "unable_to_convert_extern_ref_type").encode(env)
                            }
                            Val::FuncRef(_) => {
                                (atoms::error(), "unable_to_convert_func_ref_type").encode(env)
                            }
                        })
                    }
                    // Callback context will contain memory (plus globals, tables etc later).
                    // This will allow Elixir callback to operate on these objects.
                    let callback_context = Term::map_new(env);

                    let memory_resource = ResourceArc::new(MemoryResource {
                        memory: Mutex::new(ctx.memory().clone()),
                    });
                    let callback_context = match Term::map_put(
                        callback_context,
                        atoms::memory().encode(env),
                        memory_resource.encode(env),
                    ) {
                        Ok(map) => map,
                        _ => unreachable!(),
                    };
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

                // Wait for the thread to start up - `receive_callback_result` is responsible for that.
                let mut result = callback_token.token.return_values.lock().unwrap();
                while result.is_none() {
                    result = callback_token.token.continue_signal.wait(result).unwrap();
                }

                let result: &(bool, Vec<RustValue>) = result
                    .as_ref()
                    .expect("expect callback token to contain a result");
                match result {
                    (true, v) => Ok(map_to_wasmer_values(v.to_vec())),
                    (false, _) => Err(RuntimeError::new("the elixir callback threw an exception")),
                }
            },
        );

        Ok(function)
    }
}

fn term_to_arg_type(term: Term) -> Result<Type, Error> {
    match Atom::from_term(term) {
        Ok(atom) => {
            if atoms::i32().eq(&atom) {
                Ok(Type::I32)
            } else if atoms::i64().eq(&atom) {
                Ok(Type::I64)
            } else if atoms::f32().eq(&atom) {
                Ok(Type::F32)
            } else if atoms::f64().eq(&atom) {
                Ok(Type::F64)
            } else if atoms::v128().eq(&atom) {
                Ok(Type::V128)
            } else {
                Err(Error::Atom("unknown"))
            }
        }
        Err(_) => Err(Error::Atom("not_an_atom")),
    }
}
