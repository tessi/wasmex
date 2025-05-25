#[allow(warnings)]
mod bindings;

use bindings::exports::wasmex::simple::add::Guest;

struct Component;

impl Guest for Component {
    fn add(x:u32,y:u32,) -> u32 {
        x.saturating_add(y)
    }
}

bindings::export!(Component with_types_in bindings);
