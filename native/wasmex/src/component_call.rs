use rustler::{Encoder, Env, Error, ResourceArc, Term};
use wasmtime::component::{types::ComponentFunc, ComponentNamedList, Func, Lower, Type, Val};
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

fn encode_binary(env: Env<'_>, bytes: Vec<u8>) -> Term<'_> {
    if bytes.is_empty() {
        return "".encode(env);
    }
    let resource = ResourceArc::new(ComponentBinary(bytes));
    resource.make_binary(env, |data| &data.0).encode(env)
}

pub(crate) enum ByteListOutputParams {
    Empty,
    U32(u32),
    String(String),
    U32String(u32, String),
}

impl ByteListOutputParams {
    fn prepare(types: &[Type], terms: &[Term]) -> Result<Option<Self>, Error> {
        Ok(match (types, terms) {
            ([], []) => Some(Self::Empty),
            ([Type::U32], [number]) => Some(Self::U32(component_u32(number)?)),
            ([Type::String], [text]) => Some(Self::String(component_string(text)?)),
            ([Type::U32, Type::String], [number, text]) => Some(Self::U32String(
                component_u32(number)?,
                component_string(text)?,
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
            // Lift into an owned Vec before Wasmtime runs the guest's post-return hook.
            if fallible {
                let function = function.typed::<P, (WitResult<Vec<u8>>,)>(&*store)?;
                let (result,) = function.call_async(store, params).await?;
                Ok(ComponentCallResult::BinaryResult(result))
            } else {
                let function = function.typed::<P, (Vec<u8>,)>(&*store)?;
                let (bytes,) = function.call_async(store, params).await?;
                Ok(ComponentCallResult::Binary(bytes))
            }
        }

        match self {
            Self::Empty => call_typed(function, store, (), fallible).await,
            Self::U32(number) => call_typed(function, store, (number,), fallible).await,
            Self::String(text) => call_typed(function, store, (text,), fallible).await,
            Self::U32String(number, text) => {
                call_typed(function, store, (number, text), fallible).await
            }
        }
    }
}

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
        function: Func,
        params: ByteListOutputParams,
        fallible: bool,
    },
}

pub(crate) enum ComponentCallResult {
    Dynamic(Vec<Val>, ComponentFunc),
    Integer(WitResult<u32>),
    Count(u32),
    Binary(Vec<u8>),
    BinaryResult(WitResult<Vec<u8>>),
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

        if binary_byte_lists {
            let fallible = matches!(&result, Type::Result(result)
                if result.ok().is_some_and(|ty| is_byte_list(&ty)) && result.err() == Some(Type::String));
            if is_byte_list(&result) || fallible {
                return Ok(
                    ByteListOutputParams::prepare(param_types, terms)?.map(|params| {
                        Self::ByteListOutput {
                            function,
                            params,
                            fallible,
                        }
                    }),
                );
            }
        }
        Ok(None)
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
            Self::ByteListOutput {
                function,
                params,
                fallible,
            } => params.call(function, store, fallible).await,
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
            Self::Binary(bytes) => (atoms::ok(), encode_binary(env, bytes)).encode(env),
            Self::BinaryResult(result) => {
                (atoms::ok(), result.map(|bytes| encode_binary(env, bytes))).encode(env)
            }
        }
    }
}
