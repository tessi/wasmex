extern "C" {
    fn imported_sum(a: i32, b: i32) -> i32;
}

#[no_mangle]
pub extern "C" fn sum(from: i32, to: i32) -> i32 {
    let result = unsafe { imported_sum(from, to) };
    result
}
