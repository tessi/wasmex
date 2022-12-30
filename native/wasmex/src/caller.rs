use once_cell::sync::Lazy;
use std::{collections::HashMap, sync::Mutex};
use wasmtime::Caller;

use crate::store::StoreData;

static GLOBAL_DATA: Lazy<Mutex<HashMap<i32, Caller<StoreData>>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

pub(crate) fn get_caller(token: &i32) -> Option<&Caller<'_, StoreData>> {
    let map = &*(GLOBAL_DATA.lock().unwrap());
    map.get(token).map(|caller| unsafe {
        std::mem::transmute::<&Caller<'_, StoreData>, &Caller<'_, StoreData>>(caller)
    })
}

pub(crate) fn get_caller_mut(token: &i32) -> Option<&mut Caller<'_, StoreData>> {
    let map = &mut *(GLOBAL_DATA.lock().unwrap());
    map.get_mut(token).map(|caller| unsafe {
        std::mem::transmute::<&mut Caller<'_, StoreData>, &mut Caller<'_, StoreData>>(caller)
    })
}

pub(crate) fn set_caller(caller: Caller<StoreData>) -> i32 {
    let mut map = GLOBAL_DATA.lock().unwrap();
    // TODO: prevent duplicates by throwing the dice again when the id is already known
    let token = rand::random();
    let caller =
        unsafe { std::mem::transmute::<Caller<'_, StoreData>, Caller<'static, StoreData>>(caller) };
    map.insert(token, caller);
    token
}

pub(crate) fn remove_caller(token: i32) {
    let mut map = GLOBAL_DATA.lock().unwrap();
    map.remove(&token);
}
