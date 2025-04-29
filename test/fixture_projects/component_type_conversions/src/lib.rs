#[allow(warnings)]
mod bindings;

use bindings::Guest;
use wasi::random::random::get_random_bytes;

struct Component;

impl Guest for Component {
    fn export_id_string(str: String) -> String {
        bindings::import_id_string(&str)
    }

    fn export_id_u8(int: u8) -> u8 {
        bindings::import_id_u8(int)
    }

    fn export_id_u16(int: u16) -> u16 {
        bindings::import_id_u16(int)
    }
    
    fn export_id_u32(int: u32) -> u32 {
        bindings::import_id_u32(int)
    }

    fn export_id_u64(int: u64) -> u64 {
        bindings::import_id_u64(int)
    }

    fn export_id_s8(int: i8) -> i8 {
        bindings::import_id_s8(int)
    }

    fn export_id_s16(int: i16) -> i16 {
        bindings::import_id_s16(int)
    }

    fn export_id_s32(int: i32) -> i32 {
        bindings::import_id_s32(int)
    }

    fn export_id_s64(int: i64) -> i64 {
        bindings::import_id_s64(int)
    }

    fn export_id_f32(float: f32) -> f32 {
        bindings::import_id_f32(float)
    }

    fn export_id_f64(float: f64) -> f64 {
        bindings::import_id_f64(float)
    }

    fn export_id_bool(boolean: bool) -> bool {
        bindings::import_id_bool(boolean)
    }

    fn export_id_char(chr: char) -> char {
        bindings::import_id_char(chr)
    }

    fn export_id_list_u8(list: Vec<u8>) -> Vec<u8> {
        bindings::import_id_list_u8(&list)
    }

    fn export_id_tuple_u8_string((i,s): (u8, String)) -> (u8, String) {
        bindings::import_id_tuple_u8_string((i,&s))
    }

    fn export_id_flags(f: bindings::Permission) -> bindings::Permission {
        bindings::import_id_flags(f)
    }

    fn export_id_variant(v: bindings::VariantType) -> bindings::VariantType {
        bindings::import_id_variant(&v)
    }

    fn export_id_enum(e: bindings::EnumType) -> bindings::EnumType {
        bindings::import_id_enum(e)
    }

    fn export_id_record_complex(r: bindings::ComplexType) -> bindings::ComplexType {
        bindings::import_id_record_complex(&r)
    }

    fn get_random_bytes(len: u32) -> Vec<u8> {
        get_random_bytes(len.into())
    }
    
    fn export_id_point(p: bindings::Point) -> bindings::Point {
        bindings::import_id_point(p)
    }
    
    fn export_id_option_u8(o: Option<u8>) -> Option<u8> {
        bindings::import_id_option_u8(o)
    }
    fn export_id_result_u8_string(r: Result<u8, String>) -> Result<u8, String> {
        match r {
            Ok(v) => bindings::import_id_result_u8_string(Ok(v)),
            Err(e) => bindings::import_id_result_u8_string(Err(&e))
        }
    }
    
    fn export_id_result_u8_none(r: Result<u8, ()>) -> Result<u8, ()> {
        bindings::import_id_result_u8_none(r)
    }
    
    fn export_id_result_none_string(r: Result<(), String>) -> Result<(), String> {
        match r {
            Ok(()) => bindings::import_id_result_none_string(Ok(())),
            Err(e) => bindings::import_id_result_none_string(Err(&e))
        }
    }
    
    fn export_id_result_none_none(r: Result<(), ()>) -> Result<(), ()> {
        bindings::import_id_result_none_none(r)
    }
}

bindings::export!(Component with_types_in bindings);
