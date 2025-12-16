use crate::{
    bindings::exports::component::counter::types::{self, GuestCounter},
    counter::Counter,
};

mod bindings;
mod counter;

struct Component;

impl types::Guest for Component {
    type Counter = Counter;

    #[allow(async_fn_in_trait)]
    fn make_counter(initial: u32) -> types::Counter {
        types::Counter::new(Counter::new(initial))
    }

    #[allow(async_fn_in_trait)]
    fn use_counter(c: types::CounterBorrow<'_>) -> u32 {
        let counter = c.get::<Counter>();
        counter.get_value()
    }
}
