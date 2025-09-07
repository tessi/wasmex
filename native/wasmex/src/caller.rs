use std::{
    collections::HashMap,
    sync::{LazyLock, Mutex},
};
use wasmtime::Caller;

use crate::store::StoreData;

// Thread-safe map to store Wasmtime Caller instances under their token id
// A token can be obtained by passing a `Caller` to `set_caller` in exchange for a fresh token.
// That token can then be used to retrieve references to the `Caller` instance later.
// This is needed to pass down the `Caller` to host functions that are invoked from Wasm but Rust
// didn't let us do that directly.
static CALLER_MAP: LazyLock<Mutex<HashMap<i32, Caller<StoreData>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

pub(crate) fn get_caller(token: &i32) -> Option<&Caller<'_, StoreData>> {
    let map = &*(CALLER_MAP.lock().unwrap());
    map.get(token).map(|caller| unsafe {
        std::mem::transmute::<&Caller<'_, StoreData>, &Caller<'_, StoreData>>(caller)
    })
}

pub(crate) fn get_caller_mut(token: &mut i32) -> Option<&mut Caller<'_, StoreData>> {
    let map = &mut *(CALLER_MAP.lock().unwrap());
    map.get_mut(token).map(|caller| unsafe {
        std::mem::transmute::<&mut Caller<'_, StoreData>, &mut Caller<'_, StoreData>>(caller)
    })
}

pub(crate) fn set_caller(caller: Caller<StoreData>) -> i32 {
    let mut map = CALLER_MAP.lock().unwrap();
    // TODO: prevent duplicates by throwing the dice again when the id is already known
    let token = rand::random();
    let caller =
        unsafe { std::mem::transmute::<Caller<'_, StoreData>, Caller<'static, StoreData>>(caller) };
    map.insert(token, caller);
    token
}

pub(crate) fn remove_caller(token: i32) {
    let mut map = CALLER_MAP.lock().unwrap();
    map.remove(&token);
}
