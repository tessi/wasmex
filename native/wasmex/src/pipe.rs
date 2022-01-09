//! A Pipe is a file buffer hold in memory.
//! It can, for example, be used to replace stdin/stdout/stderr of a WASI module.

use std::collections::VecDeque;
use std::io::Write;
use std::io::{self, Read, Seek};
use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};

use rustler::resource::ResourceArc;
use rustler::{Atom, Encoder, Term};

use wasmer_wasi::{VirtualFile, WasiFsError};

use crate::atoms;

/// For piping stdio. Stores all output / input in a byte-vector.
#[derive(Debug, Default, Serialize, Deserialize)]
pub struct Pipe {
    buffer: Arc<Mutex<VecDeque<u8>>>,
}

impl Pipe {
    pub fn new() -> Self {
        Self::default()
    }
}

impl Clone for Pipe {
    fn clone(&self) -> Self {
        Pipe {
            buffer: self.buffer.clone(),
        }
    }
}

impl Read for Pipe {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let mut buffer = self.buffer.lock().unwrap();
        let amt = std::cmp::min(buf.len(), buffer.len());
        for (i, byte) in buffer.drain(..amt).enumerate() {
            buf[i] = byte;
        }
        Ok(amt)
    }
}

impl Write for Pipe {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let mut buffer = self.buffer.lock().unwrap();
        buffer.extend(buf);
        Ok(buf.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl Seek for Pipe {
    fn seek(&mut self, _pos: io::SeekFrom) -> io::Result<u64> {
        Err(io::Error::new(
            io::ErrorKind::Other,
            "can not seek in a pipe",
        ))
    }
}

impl VirtualFile for Pipe {
    fn last_accessed(&self) -> u64 {
        0
    }
    fn last_modified(&self) -> u64 {
        0
    }
    fn created_time(&self) -> u64 {
        0
    }
    fn size(&self) -> u64 {
        let buffer = self.buffer.lock().unwrap();
        buffer.len() as u64
    }
    fn set_len(&mut self, len: u64) -> Result<(), WasiFsError> {
        let mut buffer = self.buffer.lock().unwrap();
        buffer.resize(len as usize, 0);
        Ok(())
    }
    fn unlink(&mut self) -> Result<(), WasiFsError> {
        Ok(())
    }
    fn bytes_available(&self) -> Result<usize, WasiFsError> {
        let buffer = self.buffer.lock().unwrap();
        Ok(buffer.len())
    }

    fn sync_to_disk(&self) -> Result<(), WasiFsError> {
        Ok(())
    }
}

pub struct PipeResource {
    pub pipe: Mutex<Pipe>,
}

#[derive(NifTuple)]
pub struct PipeResourceResponse {
    ok: rustler::Atom,
    resource: ResourceArc<PipeResource>,
}

#[rustler::nif(name = "pipe_create")]
pub fn create() -> PipeResourceResponse {
    let pipe = Pipe::new();
    let pipe_resource = ResourceArc::new(PipeResource {
        pipe: Mutex::new(pipe),
    });

    PipeResourceResponse {
        ok: atoms::ok(),
        resource: pipe_resource,
    }
}

#[rustler::nif(name = "pipe_size")]
pub fn size(resource: ResourceArc<PipeResource>) -> u64 {
    resource.pipe.lock().unwrap().size()
}

#[rustler::nif(name = "pipe_set_len")]
pub fn set_len(resource: ResourceArc<PipeResource>, len: u64) -> Atom {
    let mut pipe = resource.pipe.lock().unwrap();

    match pipe.set_len(len) {
        Ok(_) => atoms::ok(),
        _ => atoms::error(),
    }
}

#[rustler::nif(name = "pipe_read_binary")]
pub fn read_binary(resource: ResourceArc<PipeResource>) -> String {
    let mut pipe = resource.pipe.lock().unwrap();
    let mut buffer = String::new();

    (*pipe).read_to_string(&mut buffer).unwrap();
    buffer
}

#[rustler::nif(name = "pipe_write_binary")]
pub fn write_binary(
    env: rustler::Env,
    resource: ResourceArc<PipeResource>,
    content: String,
) -> Term {
    let mut pipe = resource.pipe.lock().unwrap();

    match (*pipe).write(content.as_bytes()) {
        Ok(bytes_written) => (atoms::ok(), bytes_written).encode(env),
        _ => atoms::error().encode(env),
    }
}
