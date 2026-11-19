use rustler::{Binary, Encoder, Env, Error, ResourceArc, Term};
use wasmtime::component::{types::ComponentFunc, Func, Type, TypedFunc, Val};
use wasmtime::Store;

use crate::atoms;
use crate::component_type_conversion::{convert_params, encode_result, term_to_val};
use crate::store::ComponentStoreData;

type WitResult<T> = Result<T, String>;

#[derive(Debug)]
struct ComponentBinary(Vec<u8>);

#[rustler::resource_impl()]
impl rustler::Resource for ComponentBinary {}

pub(crate) enum ComponentCall {
    Dynamic {
        function: Func,
        function_type: ComponentFunc,
        params: Vec<Val>,
    },
    ByteListInput {
        function: TypedFunc<(Vec<u8>,), (WitResult<u32>,)>,
        bytes: Vec<u8>,
    },
    ByteListOutput {
        function: TypedFunc<(u32, String), (WitResult<Vec<u8>>,)>,
        params: (u32, String),
    },
}

pub(crate) enum ComponentCallResult {
    Dynamic(Vec<Val>, ComponentFunc),
    Integer(WitResult<u32>),
    Binary(WitResult<Vec<u8>>),
}

impl ComponentCall {
    pub(crate) fn prepare(
        function: Func,
        store: &Store<ComponentStoreData>,
        terms: Vec<Term>,
        binary_byte_lists: bool,
    ) -> Result<Self, Error> {
        let function_type = function.ty(store);
        let param_types = function_type.params().map(|(_, ty)| ty).collect::<Vec<_>>();

        if let Some(call) = Self::prepare_typed(
            function,
            store,
            &function_type,
            &param_types,
            &terms,
            binary_byte_lists,
        )? {
            return Ok(call);
        }

        let params = convert_params(&param_types, terms)?;
        Ok(Self::Dynamic {
            function,
            function_type,
            params,
        })
    }

    fn prepare_typed(
        function: Func,
        store: &Store<ComponentStoreData>,
        function_type: &ComponentFunc,
        param_types: &[Type],
        terms: &[Term],
        binary_byte_lists: bool,
    ) -> Result<Option<Self>, Error> {
        let mut results = function_type.results();
        let (Some(Type::Result(result)), None) = (results.next(), results.next()) else {
            return Ok(None);
        };
        if result.err() != Some(Type::String) {
            return Ok(None);
        }

        match (param_types, terms, result.ok()) {
            ([Type::List(list)], [term], Some(Type::U32))
                if list.ty() == Type::U8 && term.is_binary() =>
            {
                let Ok(function) = function.typed(store) else {
                    return Ok(None);
                };
                // The binary is borrowed from the NIF environment here. Own a compact
                // copy for the async call, which outlives that environment access.
                let bytes = term.decode::<Binary>()?.as_slice().to_vec();
                Ok(Some(Self::ByteListInput { function, bytes }))
            }
            ([Type::U32, Type::String], [first, second], Some(Type::List(list)))
                if binary_byte_lists && list.ty() == Type::U8 =>
            {
                let Ok(function) = function.typed(store) else {
                    return Ok(None);
                };
                let first = term_to_val(first, &Type::U32, vec![])?;
                let second = term_to_val(second, &Type::String, vec![])?;
                let (Val::U32(first), Val::String(second)) = (first, second) else {
                    unreachable!("parameter conversion returned a different WIT type");
                };
                Ok(Some(Self::ByteListOutput {
                    function,
                    params: (first, second),
                }))
            }
            _ => Ok(None),
        }
    }

    pub(crate) async fn call(
        self,
        store: &mut Store<ComponentStoreData>,
    ) -> wasmtime::Result<ComponentCallResult> {
        match self {
            Self::Dynamic {
                function,
                function_type,
                params,
            } => {
                let mut values = vec![Val::Bool(false); function_type.results().len()];
                function.call_async(store, &params, &mut values).await?;
                Ok(ComponentCallResult::Dynamic(values, function_type))
            }
            Self::ByteListInput { function, bytes } => {
                let (result,) = function.call_async(store, (bytes,)).await?;
                Ok(ComponentCallResult::Integer(result))
            }
            Self::ByteListOutput { function, params } => {
                let (result,) = function.call_async(store, params).await?;
                Ok(ComponentCallResult::Binary(result))
            }
        }
    }
}

impl ComponentCallResult {
    pub(crate) fn encode(self, env: Env<'_>, binary_byte_lists: bool) -> Term<'_> {
        match self {
            Self::Dynamic(values, function_type) => {
                encode_result(env, &values, &function_type, binary_byte_lists)
            }
            Self::Integer(result) => (atoms::ok(), result).encode(env),
            Self::Binary(result) => {
                let result = result.map(|bytes| {
                    if bytes.is_empty() {
                        return "".encode(env);
                    }
                    let resource = ResourceArc::new(ComponentBinary(bytes));
                    resource.make_binary(env, |data| &data.0).encode(env)
                });
                (atoms::ok(), result).encode(env)
            }
        }
    }
}
