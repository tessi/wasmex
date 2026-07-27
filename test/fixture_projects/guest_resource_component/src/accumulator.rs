use std::cell::Cell;
use std::sync::atomic::{AtomicU32, Ordering};

use crate::bindings::exports::wasmex::resources::counters::{
    Accumulator as AccumulatorResource, AccumulatorBorrow, GuestAccumulator,
    Label as LabelResource,
};
use crate::label::Label;

pub struct Accumulator {
    value: Cell<u32>,
}

static DROP_COUNT: AtomicU32 = AtomicU32::new(0);

impl Accumulator {
    pub fn new(initial: u32) -> Self {
        <Self as GuestAccumulator>::new(initial)
    }
}

impl Drop for Accumulator {
    fn drop(&mut self) {
        if self.value.get() == u32::MAX - 1 {
            loop {
                core::hint::spin_loop();
            }
        }
        DROP_COUNT.fetch_add(1, Ordering::Relaxed);
    }
}

pub fn drop_count() -> u32 {
    DROP_COUNT.load(Ordering::Relaxed)
}

pub fn reset_drop_count() {
    DROP_COUNT.store(0, Ordering::Relaxed);
}

impl GuestAccumulator for Accumulator {
    fn new(initial: u32) -> Self {
        if initial == u32::MAX {
            loop {
                core::hint::spin_loop();
            }
        }
        Self {
            value: Cell::new(initial),
        }
    }

    fn with_value(value: u32) -> AccumulatorResource {
        AccumulatorResource::new(Self::new(value))
    }

    fn add_other(&self, other: AccumulatorBorrow<'_>) -> u32 {
        self.value.get() + other.get::<Self>().value.get()
    }

    fn take_other(&self, other: AccumulatorResource) -> u32 {
        self.value.get() + other.get::<Self>().value.get()
    }

    fn take_other_with(&self, other: AccumulatorResource, add: u32) -> u32 {
        self.value.get() + other.get::<Self>().value.get() + add
    }

    fn take_two(&self, first: AccumulatorResource, second: AccumulatorResource) -> u32 {
        self.value.get() + first.get::<Self>().value.get() + second.get::<Self>().value.get()
    }

    fn make_label(&self, text: String) -> LabelResource {
        LabelResource::new(Label::new(text))
    }

    fn maybe_label(&self, text: Option<String>) -> Option<LabelResource> {
        text.map(|text| LabelResource::new(Label::new(text)))
    }

    fn hang(&self) {
        loop {
            core::hint::spin_loop();
        }
    }

    fn increment(&self) -> u32 {
        let value = self.value.get() + 1;
        self.value.set(value);
        value
    }

    fn get_value(&self) -> u32 {
        self.value.get()
    }

    fn reset(&self, value: u32) {
        self.value.set(value);
    }

    fn is_in_range(&self, a: u32, b: u32) -> bool {
        let value = self.value.get();
        (a <= value && value <= b) || (b <= value && value <= a)
    }
}
