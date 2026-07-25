//! A Pipe is a file buffer hold in memory.
//! It can, for example, be used to replace stdin/stdout/stderr of a WASI module.

use rustler::{Encoder, ResourceArc, Term};
use std::io::{self, Cursor, Read, Seek, Write};
use std::pin::Pin;
use std::sync::{Arc, Mutex, RwLock};
use std::task::{Context, Poll};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use wasmtime_wasi::cli::{IsTerminal, StdinStream, StdoutStream};

use crate::atoms;

/// For piping stdio. Stores all output / input in a byte-vector.
#[derive(Debug, Default)]
pub struct Pipe {
    buffer: Arc<RwLock<Cursor<Vec<u8>>>>,
}

impl Pipe {
    pub fn new() -> Self {
        Self::default()
    }
    fn borrow(&self) -> std::sync::RwLockWriteGuard<'_, Cursor<Vec<u8>>> {
        RwLock::write(&self.buffer).unwrap()
    }

    fn size(&self) -> u64 {
        let buffer = &*(self.borrow());
        buffer.get_ref().len() as u64
    }
}

impl Clone for Pipe {
    fn clone(&self) -> Self {
        Self {
            buffer: self.buffer.clone(),
        }
    }
}

impl Read for Pipe {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let buffer = &mut *(self.borrow());
        buffer.read(buf)
    }
}

impl Write for Pipe {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let buffer = &mut *(self.borrow());
        buffer.write(buf)
    }

    fn flush(&mut self) -> io::Result<()> {
        let buffer = &mut *(self.borrow());
        buffer.flush()
    }
}

impl Seek for Pipe {
    fn seek(&mut self, pos: io::SeekFrom) -> io::Result<u64> {
        let buffer = &mut *(self.borrow());
        buffer.seek(pos)
    }
}

impl AsyncRead for Pipe {
    fn poll_read(
        mut self: Pin<&mut Self>,
        _cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let read = Read::read(&mut *self, buf.initialize_unfilled())?;
        buf.advance(read);
        Poll::Ready(Ok(()))
    }
}

impl AsyncWrite for Pipe {
    fn poll_write(
        mut self: Pin<&mut Self>,
        _cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        Poll::Ready(Write::write(&mut *self, buf))
    }

    fn poll_flush(mut self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Write::flush(&mut *self))
    }

    fn poll_shutdown(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }
}

impl IsTerminal for Pipe {
    fn is_terminal(&self) -> bool {
        false
    }
}

impl StdinStream for Pipe {
    fn async_stream(&self) -> Box<dyn AsyncRead + Send + Sync> {
        Box::new(self.clone())
    }
}

impl StdoutStream for Pipe {
    fn async_stream(&self) -> Box<dyn AsyncWrite + Send + Sync> {
        Box::new(self.clone())
    }
}

pub struct PipeResource {
    pub pipe: Mutex<Pipe>,
}

#[rustler::resource_impl()]
impl rustler::Resource for PipeResource {}

#[rustler::nif(name = "pipe_new")]
pub fn new() -> Result<ResourceArc<PipeResource>, rustler::Error> {
    let pipe = Pipe::new();
    let pipe_resource = ResourceArc::new(PipeResource {
        pipe: Mutex::new(pipe),
    });

    Ok(pipe_resource)
}

#[rustler::nif(name = "pipe_size")]
pub fn size(pipe_resource: ResourceArc<PipeResource>) -> u64 {
    let pipe: &Pipe = &pipe_resource.pipe.lock().unwrap();
    pipe.size()
}

#[rustler::nif(name = "pipe_seek")]
pub fn seek(
    pipe_resource: ResourceArc<PipeResource>,
    pos: u64,
) -> rustler::NifResult<rustler::Atom> {
    let pipe: &mut Pipe = &mut pipe_resource.pipe.lock().unwrap();

    Seek::seek(pipe, io::SeekFrom::Start(pos))
        .map_err(|err| rustler::Error::Term(Box::new(err.to_string())))
        .map(|_| atoms::ok())
}

#[rustler::nif(name = "pipe_read_binary", schedule = "DirtyCpu")]
pub fn read_binary(pipe_resource: ResourceArc<PipeResource>) -> String {
    let mut pipe = pipe_resource.pipe.lock().unwrap();
    let mut buffer = String::new();

    (*pipe).read_to_string(&mut buffer).unwrap();
    buffer
}

#[rustler::nif(name = "pipe_write_binary", schedule = "DirtyCpu")]
pub fn write_binary(
    env: rustler::Env,
    pipe_resource: ResourceArc<PipeResource>,
    content: String,
) -> Term {
    let mut pipe = pipe_resource.pipe.lock().unwrap();

    match (*pipe).write(content.as_bytes()) {
        Ok(bytes_written) => (atoms::ok(), bytes_written).encode(env),
        _ => atoms::error().encode(env),
    }
}
