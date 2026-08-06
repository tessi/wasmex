mod bindings;

use bindings::exports::wasmex::host_resources::tests::Guest;
use bindings::wasmex::host_resources::counters::{Counter, Label};

struct Component;

impl Guest for Component {
    fn run_basic(initial: u32) -> u32 {
        let counter = Counter::new(initial);
        let incremented = counter.increment();
        incremented + counter.value()
    }

    fn run_borrow(first: u32, second: u32) -> u32 {
        let counter = Counter::new(first);
        let other = Counter::new(second);
        counter.add_other(&other)
    }

    fn run_take(first: u32, second: u32) -> u32 {
        let counter = Counter::new(first);
        let other = Counter::new(second);
        counter.take_other(other)
    }

    fn run_static(value: u32) -> u32 {
        let counter = Counter::with_value(value);
        counter.value()
    }

    fn run_pair(first: u32, second: u32) -> u32 {
        let (first, second) = Counter::make_pair(first, second);
        first.value() + second.value()
    }

    fn run_maybe(value: Option<u32>) -> Option<u32> {
        Counter::maybe(value).map(|counter| counter.value())
    }

    fn run_label(text: String) -> String {
        Label::new(&text).text()
    }
}
