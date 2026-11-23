use rustler::{types::tuple, Error, Term};
use wasmtime::component::{ComponentNamedList, Lift, LinkerInstance, Lower, Type, Val};

use super::{ComponentFunc, ImportCallback};
use crate::atoms;
use crate::component_type_conversion::{
    component_string, component_u32, decode_byte_list, is_byte_list,
};
use crate::store::ComponentStoreData;

impl ImportCallback {
    pub(super) fn link_byte_list(
        &self,
        linker: &mut LinkerInstance<ComponentStoreData>,
        ty: &ComponentFunc,
    ) -> wasmtime::Result<bool> {
        let mut results = ty.results();
        let (Some(result), None) = (results.next(), results.next()) else {
            return Ok(false);
        };
        if ty.async_() {
            return Ok(false);
        }
        match ty.params().map(|(_, ty)| ty).collect::<Vec<_>>().as_slice() {
            [] => self.link_result(linker, ty, &result, |()| vec![]),
            [Type::U32] => self.link_result(linker, ty, &result, |(key,)| vec![Val::U32(key)]),
            [Type::String] => {
                self.link_result(linker, ty, &result, |(key,)| vec![Val::String(key)])
            }
            _ => Ok(false),
        }
    }

    fn link_result<P: ComponentNamedList + Lift + 'static>(
        &self,
        linker: &mut LinkerInstance<ComponentStoreData>,
        ty: &ComponentFunc,
        result: &Type,
        params: fn(P) -> Vec<Val>,
    ) -> wasmtime::Result<bool> {
        match result {
            bytes if is_byte_list(bytes) => self.register(linker, ty, params, decode_byte_list)?,
            Type::Option(opt) if is_byte_list(&opt.ty()) => {
                self.register(linker, ty, params, |term| {
                    if atoms::none() == term {
                        return Ok(None);
                    }
                    let (tag, value) = tagged_value(term)?;
                    if atoms::some() != tag {
                        return Err(Error::BadArg);
                    }
                    decode_byte_list(value).map(Some)
                })?
            }
            Type::Result(r) if r.ok().is_some_and(|ok| is_byte_list(&ok)) => match r.err() {
                Some(Type::String) => self.register(linker, ty, params, |term| {
                    decode_result(term, |error| component_string(&error))
                })?,
                Some(Type::U32) => self.register(linker, ty, params, |term| {
                    decode_result(term, |error| component_u32(&error))
                })?,
                None => self.register(linker, ty, params, |term| {
                    if atoms::error() == term {
                        return Ok(Err(()));
                    }
                    decode_result(term, |_| Err(Error::BadArg))
                })?,
                _ => return Ok(false),
            },
            _ => return Ok(false),
        }
        Ok(true)
    }

    fn register<P, R>(
        &self,
        linker: &mut LinkerInstance<ComponentStoreData>,
        ty: &ComponentFunc,
        params: fn(P) -> Vec<Val>,
        decode: fn(Term) -> Result<R, Error>,
    ) -> wasmtime::Result<()>
    where
        P: ComponentNamedList + Lift + 'static,
        R: Lower + 'static,
    {
        let callback = self.clone();
        let ty = ty.clone();
        linker.func_wrap_async(&self.name, move |mut store, args: P| {
            let callback = callback.clone();
            let ty = ty.clone();
            Box::new(async move {
                let reply = callback.invoke(&mut store, &ty, &params(args)).await?;
                reply
                    .env
                    .run(|env| decode(reply.result.load(env)))
                    .map(|value| (value,))
                    .map_err(|err| wasmtime::Error::msg(format!("{err:?}")))
            })
        })
    }
}

// The dynamic converter reads the tag and payload and accepts trailing tuple elements.
fn tagged_value(term: Term) -> Result<(Term, Term), Error> {
    match tuple::get_tuple(term)?.as_slice() {
        [tag, value, ..] => Ok((*tag, *value)),
        _ => Err(Error::BadArg),
    }
}

fn decode_result<E>(
    term: Term,
    decode_error: impl FnOnce(Term) -> Result<E, Error>,
) -> Result<Result<Vec<u8>, E>, Error> {
    let (tag, value) = tagged_value(term)?;
    if atoms::ok() == tag {
        decode_byte_list(value).map(Ok)
    } else if atoms::error() == tag {
        decode_error(value).map(Err)
    } else {
        Err(Error::BadArg)
    }
}
