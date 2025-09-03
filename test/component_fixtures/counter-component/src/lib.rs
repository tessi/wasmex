#![cfg(target_os = "wasi")]

wit_bindgen::generate!({
    path: "wit",
    world: "example",
});

use self::exports::component::counter::types::{Guest as TypesGuest, GuestCounter, Counter as TypesCounter, CounterBorrow};
use std::cell::RefCell;

struct Component;

pub struct Counter {
    value: RefCell<u32>,
}

impl Guest for Component {
    fn test() -> String {
        "Counter resource test component".to_string()
    }
}

impl TypesGuest for Component {
    type Counter = Counter;
    
    fn make_counter(initial: u32) -> TypesCounter {
        TypesCounter::new(Counter::new(initial))
    }
    
    fn use_counter(c: CounterBorrow<'_>) -> u32 {
        let counter = c.get::<Counter>();
        counter.get_value()
    }
}

impl GuestCounter for Counter {
    fn new(initial: u32) -> Self {
        Counter {
            value: RefCell::new(initial),
        }
    }
    
    fn increment(&self) -> u32 {
        let mut val = self.value.borrow_mut();
        *val += 1;
        *val
    }
    
    fn get_value(&self) -> u32 {
        *self.value.borrow()
    }
    
    fn reset(&self, value: u32) {
        *self.value.borrow_mut() = value;
    }
}

export!(Component);