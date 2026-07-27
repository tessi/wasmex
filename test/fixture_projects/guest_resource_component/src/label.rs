use crate::bindings::exports::wasmex::resources::counters::GuestLabel;

pub struct Label {
    text: String,
}

impl GuestLabel for Label {
    fn new(text: String) -> Self {
        Self { text }
    }

    fn text(&self) -> String {
        self.text.clone()
    }
}

impl Label {
    pub fn new(text: String) -> Self {
        <Self as GuestLabel>::new(text)
    }
}
