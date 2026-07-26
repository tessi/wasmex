use rustler::{
    env::SavedTerm, types::tuple::make_tuple, Encoder, Env, LocalPid, NewBinary, OwnedEnv, Term,
};

/// An owned GenServer-style reply target that can safely cross NIF boundaries.
pub struct AsyncReply {
    env: OwnedEnv,
    from: SavedTerm,
}

impl AsyncReply {
    pub fn new(from: Term<'_>) -> Self {
        let env = OwnedEnv::new();
        let from = env.save(from);
        Self { env, from }
    }

    pub fn send<T: Encoder>(self, value: T) {
        self.env.run(move |env| {
            let (pid, reference) = self
                .from
                .load(env)
                .decode::<(LocalPid, Term)>()
                .expect("async reply target must be a {pid, reference} tuple");
            let message = make_tuple(env, &[reference, value.encode(env)]);
            let _ = env.send(&pid, message);
        });
    }

    pub fn send_error(self, reason: impl Into<String>) {
        self.send((crate::atoms::error(), reason.into()));
    }

    pub fn send_binary(self, bytes: Vec<u8>) {
        self.env.run(move |env| {
            let (pid, reference) = self
                .from
                .load(env)
                .decode::<(LocalPid, Term)>()
                .expect("async reply target must be a {pid, reference} tuple");
            let mut binary = NewBinary::new(env, bytes.len());
            binary.as_mut_slice().copy_from_slice(&bytes);
            let message = make_tuple(env, &[reference, binary.into()]);
            let _ = env.send(&pid, message);
        });
    }
}

pub fn submit_error(reply: AsyncReply, error: crate::store_executor::SubmitError) {
    let reason = match error {
        crate::store_executor::SubmitError::Busy => "Wasm store command queue is full",
        crate::store_executor::SubmitError::Closed => "Wasm store is closed",
    };
    reply.send_error(reason);
}

pub fn send_saved_term(env: OwnedEnv, from: SavedTerm, value: SavedTerm) {
    env.run(|env: Env| {
        let (pid, reference) = from
            .load(env)
            .decode::<(LocalPid, Term)>()
            .expect("async reply target must be a {pid, reference} tuple");
        let message = make_tuple(env, &[reference, value.load(env)]);
        let _ = env.send(&pid, message);
    });
}
