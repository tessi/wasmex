extern "C" {
    fn imported_sum(a: u32, b: u32) -> u32;
}

#[no_mangle]
pub extern "C" fn using_imported_sum(a: u32, b: u32) -> u32 {
    unsafe { imported_sum(a, b) }
}
