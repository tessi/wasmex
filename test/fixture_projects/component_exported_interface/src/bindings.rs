// Generated by `wit-bindgen` 0.41.0. DO NOT EDIT!
// Options used:
//   * runtime_path: "wit_bindgen_rt"
#[rustfmt::skip]
#[allow(dead_code, clippy::all)]
pub mod wasmex {
    pub mod simple {
        #[allow(dead_code, async_fn_in_trait, unused_imports, clippy::all)]
        pub mod add {
            #[used]
            #[doc(hidden)]
            static __FORCE_SECTION_REF: fn() = super::super::super::__link_custom_section_describing_imports;
            use super::super::super::_rt;
            #[derive(Clone)]
            pub struct Tag {
                pub id: _rt::String,
            }
            impl ::core::fmt::Debug for Tag {
                fn fmt(
                    &self,
                    f: &mut ::core::fmt::Formatter<'_>,
                ) -> ::core::fmt::Result {
                    f.debug_struct("Tag").field("id", &self.id).finish()
                }
            }
            #[allow(unused_unsafe, clippy::all)]
            pub fn add(x: u32, y: u32) -> u32 {
                unsafe {
                    #[cfg(target_arch = "wasm32")]
                    #[link(wasm_import_module = "wasmex:simple/add@0.1.0")]
                    unsafe extern "C" {
                        #[link_name = "add"]
                        fn wit_import0(_: i32, _: i32) -> i32;
                    }
                    #[cfg(not(target_arch = "wasm32"))]
                    unsafe extern "C" fn wit_import0(_: i32, _: i32) -> i32 {
                        unreachable!()
                    }
                    let ret = unsafe { wit_import0(_rt::as_i32(&x), _rt::as_i32(&y)) };
                    ret as u32
                }
            }
            #[allow(unused_unsafe, clippy::all)]
            pub fn call_into_imported_module_func() -> u32 {
                unsafe {
                    #[cfg(target_arch = "wasm32")]
                    #[link(wasm_import_module = "wasmex:simple/add@0.1.0")]
                    unsafe extern "C" {
                        #[link_name = "call-into-imported-module-func"]
                        fn wit_import0() -> i32;
                    }
                    #[cfg(not(target_arch = "wasm32"))]
                    unsafe extern "C" fn wit_import0() -> i32 {
                        unreachable!()
                    }
                    let ret = unsafe { wit_import0() };
                    ret as u32
                }
            }
        }
        #[allow(dead_code, async_fn_in_trait, unused_imports, clippy::all)]
        pub mod get {
            #[used]
            #[doc(hidden)]
            static __FORCE_SECTION_REF: fn() = super::super::super::__link_custom_section_describing_imports;
            use super::super::super::_rt;
            pub type Tag = super::super::super::wasmex::simple::add::Tag;
            #[allow(unused_unsafe, clippy::all)]
            pub fn get() -> Tag {
                unsafe {
                    #[cfg_attr(target_pointer_width = "64", repr(align(8)))]
                    #[cfg_attr(target_pointer_width = "32", repr(align(4)))]
                    struct RetArea(
                        [::core::mem::MaybeUninit<
                            u8,
                        >; 2 * ::core::mem::size_of::<*const u8>()],
                    );
                    let mut ret_area = RetArea(
                        [::core::mem::MaybeUninit::uninit(); 2
                            * ::core::mem::size_of::<*const u8>()],
                    );
                    let ptr0 = ret_area.0.as_mut_ptr().cast::<u8>();
                    #[cfg(target_arch = "wasm32")]
                    #[link(wasm_import_module = "wasmex:simple/get@0.1.0")]
                    unsafe extern "C" {
                        #[link_name = "get"]
                        fn wit_import1(_: *mut u8);
                    }
                    #[cfg(not(target_arch = "wasm32"))]
                    unsafe extern "C" fn wit_import1(_: *mut u8) {
                        unreachable!()
                    }
                    unsafe { wit_import1(ptr0) };
                    let l2 = *ptr0.add(0).cast::<*mut u8>();
                    let l3 = *ptr0
                        .add(::core::mem::size_of::<*const u8>())
                        .cast::<usize>();
                    let len4 = l3;
                    let bytes4 = _rt::Vec::from_raw_parts(l2.cast(), len4, len4);
                    let result5 = super::super::super::wasmex::simple::add::Tag {
                        id: _rt::string_lift(bytes4),
                    };
                    result5
                }
            }
        }
    }
}
#[rustfmt::skip]
#[allow(dead_code, clippy::all)]
pub mod exports {
    pub mod wasmex {
        pub mod simple {
            #[allow(dead_code, async_fn_in_trait, unused_imports, clippy::all)]
            pub mod add {
                #[used]
                #[doc(hidden)]
                static __FORCE_SECTION_REF: fn() = super::super::super::super::__link_custom_section_describing_imports;
                use super::super::super::super::_rt;
                #[derive(Clone)]
                pub struct Tag {
                    pub id: _rt::String,
                }
                impl ::core::fmt::Debug for Tag {
                    fn fmt(
                        &self,
                        f: &mut ::core::fmt::Formatter<'_>,
                    ) -> ::core::fmt::Result {
                        f.debug_struct("Tag").field("id", &self.id).finish()
                    }
                }
                #[doc(hidden)]
                #[allow(non_snake_case)]
                pub unsafe fn _export_add_cabi<T: Guest>(arg0: i32, arg1: i32) -> i32 {
                    #[cfg(target_arch = "wasm32")] _rt::run_ctors_once();
                    let result0 = T::add(arg0 as u32, arg1 as u32);
                    _rt::as_i32(result0)
                }
                #[doc(hidden)]
                #[allow(non_snake_case)]
                pub unsafe fn _export_call_into_imported_module_func_cabi<T: Guest>() -> i32 {
                    #[cfg(target_arch = "wasm32")] _rt::run_ctors_once();
                    let result0 = T::call_into_imported_module_func();
                    _rt::as_i32(result0)
                }
                pub trait Guest {
                    fn add(x: u32, y: u32) -> u32;
                    fn call_into_imported_module_func() -> u32;
                }
                #[doc(hidden)]
                macro_rules! __export_wasmex_simple_add_0_1_0_cabi {
                    ($ty:ident with_types_in $($path_to_types:tt)*) => {
                        const _ : () = { #[unsafe (export_name =
                        "wasmex:simple/add@0.1.0#add")] unsafe extern "C" fn
                        export_add(arg0 : i32, arg1 : i32,) -> i32 { unsafe {
                        $($path_to_types)*:: _export_add_cabi::<$ty > (arg0, arg1) } }
                        #[unsafe (export_name =
                        "wasmex:simple/add@0.1.0#call-into-imported-module-func")] unsafe
                        extern "C" fn export_call_into_imported_module_func() -> i32 {
                        unsafe { $($path_to_types)*::
                        _export_call_into_imported_module_func_cabi::<$ty > () } } };
                    };
                }
                #[doc(hidden)]
                pub(crate) use __export_wasmex_simple_add_0_1_0_cabi;
            }
        }
    }
}
#[rustfmt::skip]
mod _rt {
    #![allow(dead_code, clippy::all)]
    pub use alloc_crate::string::String;
    pub fn as_i32<T: AsI32>(t: T) -> i32 {
        t.as_i32()
    }
    pub trait AsI32 {
        fn as_i32(self) -> i32;
    }
    impl<'a, T: Copy + AsI32> AsI32 for &'a T {
        fn as_i32(self) -> i32 {
            (*self).as_i32()
        }
    }
    impl AsI32 for i32 {
        #[inline]
        fn as_i32(self) -> i32 {
            self as i32
        }
    }
    impl AsI32 for u32 {
        #[inline]
        fn as_i32(self) -> i32 {
            self as i32
        }
    }
    impl AsI32 for i16 {
        #[inline]
        fn as_i32(self) -> i32 {
            self as i32
        }
    }
    impl AsI32 for u16 {
        #[inline]
        fn as_i32(self) -> i32 {
            self as i32
        }
    }
    impl AsI32 for i8 {
        #[inline]
        fn as_i32(self) -> i32 {
            self as i32
        }
    }
    impl AsI32 for u8 {
        #[inline]
        fn as_i32(self) -> i32 {
            self as i32
        }
    }
    impl AsI32 for char {
        #[inline]
        fn as_i32(self) -> i32 {
            self as i32
        }
    }
    impl AsI32 for usize {
        #[inline]
        fn as_i32(self) -> i32 {
            self as i32
        }
    }
    pub use alloc_crate::vec::Vec;
    pub unsafe fn string_lift(bytes: Vec<u8>) -> String {
        if cfg!(debug_assertions) {
            String::from_utf8(bytes).unwrap()
        } else {
            String::from_utf8_unchecked(bytes)
        }
    }
    #[cfg(target_arch = "wasm32")]
    pub fn run_ctors_once() {
        wit_bindgen_rt::run_ctors_once();
    }
    extern crate alloc as alloc_crate;
}
/// Generates `#[unsafe(no_mangle)]` functions to export the specified type as
/// the root implementation of all generated traits.
///
/// For more information see the documentation of `wit_bindgen::generate!`.
///
/// ```rust
/// # macro_rules! export{ ($($t:tt)*) => (); }
/// # trait Guest {}
/// struct MyType;
///
/// impl Guest for MyType {
///     // ...
/// }
///
/// export!(MyType);
/// ```
#[allow(unused_macros)]
#[doc(hidden)]
macro_rules! __export_adder_impl {
    ($ty:ident) => {
        self::export!($ty with_types_in self);
    };
    ($ty:ident with_types_in $($path_to_types_root:tt)*) => {
        $($path_to_types_root)*::
        exports::wasmex::simple::add::__export_wasmex_simple_add_0_1_0_cabi!($ty
        with_types_in $($path_to_types_root)*:: exports::wasmex::simple::add);
    };
}
#[doc(inline)]
pub(crate) use __export_adder_impl as export;
#[cfg(target_arch = "wasm32")]
#[unsafe(
    link_section = "component-type:wit-bindgen:0.41.0:wasmex:simple@0.1.0:adder:encoded world"
)]
#[doc(hidden)]
#[allow(clippy::octal_escapes)]
pub static __WIT_BINDGEN_COMPONENT_TYPE: [u8; 438] = *b"\
\0asm\x0d\0\x01\0\0\x19\x16wit-component-encoding\x04\0\x07\xba\x02\x01A\x02\x01\
A\x07\x01B\x06\x01r\x01\x02ids\x04\0\x03tag\x03\0\0\x01@\x02\x01xy\x01yy\0y\x04\0\
\x03add\x01\x02\x01@\0\0y\x04\0\x1ecall-into-imported-module-func\x01\x03\x03\0\x17\
wasmex:simple/add@0.1.0\x05\0\x02\x03\0\0\x03tag\x01B\x04\x02\x03\x02\x01\x01\x04\
\0\x03tag\x03\0\0\x01@\0\0\x01\x04\0\x03get\x01\x02\x03\0\x17wasmex:simple/get@0\
.1.0\x05\x02\x01B\x06\x01r\x01\x02ids\x04\0\x03tag\x03\0\0\x01@\x02\x01xy\x01yy\0\
y\x04\0\x03add\x01\x02\x01@\0\0y\x04\0\x1ecall-into-imported-module-func\x01\x03\
\x04\0\x17wasmex:simple/add@0.1.0\x05\x03\x04\0\x19wasmex:simple/adder@0.1.0\x04\
\0\x0b\x0b\x01\0\x05adder\x03\0\0\0G\x09producers\x01\x0cprocessed-by\x02\x0dwit\
-component\x070.227.1\x10wit-bindgen-rust\x060.41.0";
#[inline(never)]
#[doc(hidden)]
pub fn __link_custom_section_describing_imports() {
    wit_bindgen_rt::maybe_link_cabi_realloc();
}
