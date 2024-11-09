extern "C" {
    fn imported_sum3(a: u32, b: u32, c: u32) -> u32;
    fn imported_sumf(a: f32, b: f32) -> f32;
    fn imported_void() -> ();
}

#[no_mangle]
pub extern "C" fn using_imported_sum3(a: u32, b: u32, c: u32) -> u32 {
    unsafe { imported_sum3(a, b, c) }
}

#[no_mangle]
pub extern "C" fn using_imported_sumf(a: f32, b: f32) -> f32 {
    unsafe { imported_sumf(a, b) }
}


#[no_mangle]
pub extern "C" fn using_imported_void() {
    unsafe { imported_void() }
}
