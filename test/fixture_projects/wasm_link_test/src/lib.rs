#[link(wasm_import_module = "utils")]
extern "C" {
    fn sum(a: i32, b: i32) -> i32;
}

#[no_mangle]
pub extern "C" fn sum_range(from: i32, to: i32) -> i32 {
    let mut result = 0;

    for number in from..=to {
        result = unsafe { sum(result, number) };
    }
    
    result
}
