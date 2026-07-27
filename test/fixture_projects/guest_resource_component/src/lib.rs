use crate::{
    accumulator::Accumulator,
    bindings::exports::wasmex::resources::counters::{
        self, Accumulator as AccumulatorResource, GuestFactory, Label as LabelResource,
    },
    label::Label,
};

mod accumulator;
mod bindings;
mod label;

struct Component;

impl counters::Guest for Component {
    type Accumulator = Accumulator;
    type Factory = Factory;
    type Label = Label;
}

struct Factory;

impl GuestFactory for Factory {
    fn make_accumulator(value: u32) -> AccumulatorResource {
        AccumulatorResource::new(Accumulator::new(value))
    }

    fn make_label(text: String) -> LabelResource {
        LabelResource::new(Label::new(text))
    }

    fn make_pair(value: u32, text: String) -> (AccumulatorResource, LabelResource) {
        (Self::make_accumulator(value), Self::make_label(text))
    }

    fn drop_count() -> u32 {
        accumulator::drop_count()
    }

    fn reset_drop_count() {
        accumulator::reset_drop_count();
    }
}
