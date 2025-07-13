use rustler::{Binary, NifResult};

#[rustler::nif(name = "wat_to_wasm")]
pub fn to_wasm(env: rustler::Env, wat: String) -> NifResult<Binary> {
    let bytes = wat::parse_str(&wat)
        .map_err(|e| rustler::Error::Term(Box::new(format!("Failed to parse WAT: {e}"))))?;
    let mut binary = rustler::OwnedBinary::new(bytes.len()).unwrap();
    binary.as_mut_slice().copy_from_slice(&bytes);
    Ok(binary.release(env))
}
