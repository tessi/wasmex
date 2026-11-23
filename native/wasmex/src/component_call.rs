use rustler::{Encoder, Env, Error, ResourceArc, Term};
use wasmtime::component::{
    types::ComponentFunc, ComponentNamedList, Func, Lower, Type, TypedFunc, Val,
};
use wasmtime::Store;

use crate::atoms;
use crate::component_type_conversion::{
    component_string, component_u32, convert_params, decode_byte_list, encode_result, is_byte_list,
};
use crate::store::ComponentStoreData;

type WitResult<T> = Result<T, String>;

#[derive(Debug)]
struct ComponentBinary(Vec<u8>);

#[rustler::resource_impl()]
impl rustler::Resource for ComponentBinary {}

pub(crate) enum ByteListParams {
    Bytes(Vec<u8>),
    StringBytes(String, Vec<u8>),
    BytesString(Vec<u8>, String),
    U32Bytes(u32, Vec<u8>),
    BytesU32(Vec<u8>, u32),
}

impl ByteListParams {
    fn prepare(types: &[Type], terms: &[Term]) -> Result<Option<Self>, Error> {
        let byte_input =
            |ty: &Type, term: &Term| is_byte_list(ty) && (term.is_binary() || term.is_list());
        Ok(match (types, terms) {
            ([ty], [bytes]) if byte_input(ty, bytes) => {
                Some(Self::Bytes(decode_byte_list(*bytes)?))
            }
            ([Type::String, ty], [text, bytes]) if byte_input(ty, bytes) => Some(
                Self::StringBytes(component_string(text)?, decode_byte_list(*bytes)?),
            ),
            ([ty, Type::String], [bytes, text]) if byte_input(ty, bytes) => Some(
                Self::BytesString(decode_byte_list(*bytes)?, component_string(text)?),
            ),
            ([Type::U32, ty], [number, bytes]) if byte_input(ty, bytes) => Some(Self::U32Bytes(
                component_u32(number)?,
                decode_byte_list(*bytes)?,
            )),
            ([ty, Type::U32], [bytes, number]) if byte_input(ty, bytes) => Some(Self::BytesU32(
                decode_byte_list(*bytes)?,
                component_u32(number)?,
            )),
            _ => None,
        })
    }

    async fn call(
        self,
        function: Func,
        store: &mut Store<ComponentStoreData>,
        fallible: bool,
    ) -> wasmtime::Result<ComponentCallResult> {
        async fn call_typed<P: ComponentNamedList + Lower>(
            function: Func,
            store: &mut Store<ComponentStoreData>,
            params: P,
            fallible: bool,
        ) -> wasmtime::Result<ComponentCallResult> {
            if fallible {
                let function = function.typed::<P, (WitResult<u32>,)>(&*store)?;
                Ok(ComponentCallResult::Integer(
                    function.call_async(store, params).await?.0,
                ))
            } else {
                let function = function.typed::<P, (u32,)>(&*store)?;
                Ok(ComponentCallResult::Count(
                    function.call_async(store, params).await?.0,
                ))
            }
        }
        match self {
            Self::Bytes(bytes) => call_typed(function, store, (bytes,), fallible).await,
            Self::StringBytes(text, bytes) => {
                call_typed(function, store, (text, bytes), fallible).await
            }
            Self::BytesString(bytes, text) => {
                call_typed(function, store, (bytes, text), fallible).await
            }
            Self::U32Bytes(number, bytes) => {
                call_typed(function, store, (number, bytes), fallible).await
            }
            Self::BytesU32(bytes, number) => {
                call_typed(function, store, (bytes, number), fallible).await
            }
        }
    }
}

pub(crate) enum ComponentCall {
    Dynamic {
        function: Func,
        function_type: ComponentFunc,
        params: Vec<Val>,
    },
    ByteListInput {
        function: Func,
        params: ByteListParams,
        fallible: bool,
    },
    ByteListOutput {
        function: TypedFunc<(u32, String), (WitResult<Vec<u8>>,)>,
        params: (u32, String),
    },
}

pub(crate) enum ComponentCallResult {
    Dynamic(Vec<Val>, ComponentFunc),
    Integer(WitResult<u32>),
    Count(u32),
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
        let (Some(result), None) = (results.next(), results.next()) else {
            return Ok(None);
        };
        let fallible_count = matches!(&result, Type::Result(r)
            if r.ok() == Some(Type::U32) && r.err() == Some(Type::String));
        if result == Type::U32 || fallible_count {
            return Ok(ByteListParams::prepare(param_types, terms)?.map(|params| {
                Self::ByteListInput {
                    function,
                    params,
                    fallible: fallible_count,
                }
            }));
        }

        let Type::Result(result) = result else {
            return Ok(None);
        };
        if result.err() != Some(Type::String) {
            return Ok(None);
        }
        match (param_types, terms, result.ok()) {
            ([Type::U32, Type::String], [first, second], Some(Type::List(list)))
                if binary_byte_lists && list.ty() == Type::U8 =>
            {
                let Ok(function) = function.typed(store) else {
                    return Ok(None);
                };
                Ok(Some(Self::ByteListOutput {
                    function,
                    params: (component_u32(first)?, component_string(second)?),
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
            Self::ByteListInput {
                function,
                params,
                fallible,
            } => params.call(function, store, fallible).await,
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
            Self::Count(n) => (atoms::ok(), n).encode(env),
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
