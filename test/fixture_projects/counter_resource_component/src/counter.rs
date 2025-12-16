use std::cell::RefCell;

use crate::bindings::exports::component::counter::types::GuestCounter;

pub struct Counter {
    value: RefCell<u32>,
}

impl GuestCounter for Counter {
    #[allow(async_fn_in_trait)]
    fn new(initial: u32) -> Self {
        Counter {
            value: RefCell::new(initial),
        }
    }

    #[allow(async_fn_in_trait)]
    fn increment(&self) -> u32 {
        let mut val = self.value.borrow_mut();
        *val += 1;
        *val
    }

    #[allow(async_fn_in_trait)]
    fn get_value(&self) -> u32 {
        *self.value.borrow()
    }

    #[allow(async_fn_in_trait)]
    fn reset(&self, value: u32) -> () {
        *self.value.borrow_mut() = value;
    }

    #[allow(async_fn_in_trait)]
    fn is_in_range(&self, a: u32, b: u32) -> bool {
        let value = *self.value.borrow();
        (a <= value && value <= b) || (b <= value && value <= a)
    }
}