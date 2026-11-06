use rustler::{Binary, NifResult};

#[rustler::nif(name = "wat_to_wasm", schedule = "DirtyCpu")]
pub fn to_wasm(env: rustler::Env, wat: String) -> NifResult<Binary> {
    let bytes = wat::parse_str(&wat)
        .map_err(|e| rustler::Error::Term(Box::new(format!("Failed to parse WAT: {e}"))))?;
    Ok(rustler::OwnedBinary::from_slice(&bytes).release(env))
}
