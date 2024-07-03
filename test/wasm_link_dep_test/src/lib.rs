#[link(wasm_import_module = "calculator")]
extern "C" {
    fn sum_range(from: i32, to: i32) -> i32;
}

#[no_mangle]
pub extern "C" fn calc_seq(from: i32, to: i32) -> i32 {
    let result = unsafe { sum_range(from, to) };
    result
}
