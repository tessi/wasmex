use rustler::{
    env::SavedTerm, types::tuple::make_tuple, Encoder, LocalPid, NewBinary, OwnedEnv, Term,
};

/// An owned GenServer-style reply target that can safely cross NIF boundaries.
pub struct AsyncReply {
    env: OwnedEnv,
    pid: LocalPid,
    reference: SavedTerm,
}

impl AsyncReply {
    pub fn new(from: Term<'_>) -> rustler::NifResult<Self> {
        let (pid, reference) = from.decode::<(LocalPid, Term)>()?;
        let env = OwnedEnv::new();
        let reference = env.save(reference);
        Ok(Self {
            env,
            pid,
            reference,
        })
    }

    pub fn send<T: Encoder>(self, value: T) {
        self.env.run(move |env| {
            let message = make_tuple(env, &[self.reference.load(env), value.encode(env)]);
            let _ = env.send(&self.pid, message);
        });
    }

    pub fn send_error(self, reason: impl Into<String>) {
        self.send((crate::atoms::error(), reason.into()));
    }

    pub fn send_binary(self, bytes: Vec<u8>) {
        self.env.run(move |env| {
            let mut binary = NewBinary::new(env, bytes.len());
            binary.as_mut_slice().copy_from_slice(&bytes);
            let message = make_tuple(env, &[self.reference.load(env), binary.into()]);
            let _ = env.send(&self.pid, message);
        });
    }

    pub fn send_saved(self, source_env: OwnedEnv, value: SavedTerm) {
        let value = source_env.run(|env| self.env.save(value.load(env)));
        self.env.run(move |env| {
            let message = make_tuple(env, &[self.reference.load(env), value.load(env)]);
            let _ = env.send(&self.pid, message);
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
