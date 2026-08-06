wit_bindgen::generate!({
    path: "wit",
    world: "demo",
    generate_all,
});

use demo::wasi_error::factory;
use exports::demo::wasi_error::app::Guest;

struct Component;

impl Guest for Component {
    fn describe(message: String) -> String {
        let error = factory::make_error(&message);
        error.to_debug_string()
    }
}

export!(Component);
