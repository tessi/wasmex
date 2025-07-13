#[allow(warnings)]
mod bindings;

use bindings::wasmex::simple::get::get;

struct Component;

impl bindings::exports::wasmex::simple::add::Guest for Component {
    fn add(x:u32,y:u32,) -> u32 {
        x.saturating_add(y)
    }

    fn call_into_imported_module_func() -> u32 {
        let tag = get();
        tag.id.len() as u32
    }
}

bindings::export!(Component with_types_in bindings);
