#[no_mangle]
pub extern "C" fn sum(x: i32, y: i32) -> i32 {
    x + y
}

#[no_mangle]
pub extern "C" fn arity_0() -> i32 {
    42
}

#[no_mangle]
pub extern "C" fn i32_i32(x: i32) -> i32 {
    x
}

#[no_mangle]
pub extern "C" fn i64_i64(x: i64) -> i64 {
    x
}

#[no_mangle]
pub extern "C" fn f32_f32(x: f32) -> f32 {
    x
}

#[no_mangle]
pub extern "C" fn f64_f64(x: f64) -> f64 {
    x
}

#[no_mangle]
pub extern "C" fn i32_i64_f32_f64_f64(a: i32, b: i64, c: f32, d: f64) -> f64 {
    a as f64 + b as f64 + c as f64 + d
}

#[no_mangle]
pub extern "C" fn bool_casted_to_i32() -> bool {
    true
}

#[no_mangle]
pub extern "C" fn string() -> *const u8 {
    b"Hello, World!\0".as_ptr()
}

#[no_mangle]
pub extern "C" fn void() {}

#[no_mangle]
pub extern "C" fn string_first_byte(s: &str) -> u8 {
    match s.bytes().nth(0) {
        Some(i) => i,
        None => 0,
    }
}

#[no_mangle]
pub extern "C" fn endless_loop() -> () {
    loop {}
}
