//! A Pipe is a file buffer hold in memory.
//! It can, for example, be used to replace stdin/stdout/stderr of a WASI module.

#[cfg(not(test))]
use rustler::{Encoder, ResourceArc, Term};
use std::io::{self, Cursor, Read, Seek, Write};
use std::pin::Pin;
#[cfg(not(test))]
use std::sync::Mutex;
use std::sync::{Arc, RwLock};
use std::task::{Context, Poll};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use wasmtime_wasi::cli::{IsTerminal, StdinStream, StdoutStream};

#[cfg(not(test))]
use crate::atoms;

const DEFAULT_MAX_SIZE: usize = 256 * 1024 * 1024;

/// For piping stdio. Stores all output / input in a byte-vector.
#[derive(Debug)]
pub struct Pipe {
    buffer: Arc<RwLock<Cursor<Vec<u8>>>>,
    max_size: usize,
}

impl Default for Pipe {
    fn default() -> Self {
        Self::with_max_size(DEFAULT_MAX_SIZE)
    }
}

impl Pipe {
    pub fn new() -> Self {
        Self::default()
    }

    fn with_max_size(max_size: usize) -> Self {
        Self {
            buffer: Arc::new(RwLock::new(Cursor::new(Vec::new()))),
            max_size,
        }
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
            max_size: self.max_size,
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
        let end = usize::try_from(buffer.position())
            .ok()
            .and_then(|position| position.checked_add(buf.len()))
            .filter(|end| *end <= self.max_size)
            .ok_or_else(|| io::Error::other("Pipe maximum size exceeded"))?;

        // Reserve before changing either the contents or cursor. Keep geometric
        // growth for small writes, bounded by the configured buffer extent.
        let bytes = buffer.get_mut();
        if end > bytes.capacity() {
            let capacity = end
                .max(bytes.capacity().saturating_mul(2))
                .min(self.max_size);
            bytes
                .try_reserve_exact(capacity - bytes.len())
                .map_err(|error| io::Error::new(io::ErrorKind::OutOfMemory, error))?;
        }
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

#[cfg(not(test))]
pub struct PipeResource {
    pub pipe: Mutex<Pipe>,
}

#[cfg(not(test))]
#[rustler::resource_impl()]
impl rustler::Resource for PipeResource {}

#[cfg(not(test))]
#[rustler::nif(name = "pipe_new")]
pub fn new() -> Result<ResourceArc<PipeResource>, rustler::Error> {
    Ok(pipe_resource(Pipe::new()))
}

#[cfg(not(test))]
#[rustler::nif(name = "pipe_new_with_limit")]
pub fn new_with_limit(max_size: usize) -> Result<ResourceArc<PipeResource>, rustler::Error> {
    Ok(pipe_resource(Pipe::with_max_size(max_size)))
}

#[cfg(not(test))]
fn pipe_resource(pipe: Pipe) -> ResourceArc<PipeResource> {
    ResourceArc::new(PipeResource {
        pipe: Mutex::new(pipe),
    })
}

#[cfg(not(test))]
#[rustler::nif(name = "pipe_size")]
pub fn size(pipe_resource: ResourceArc<PipeResource>) -> u64 {
    let pipe: &Pipe = &pipe_resource.pipe.lock().unwrap();
    pipe.size()
}

#[cfg(not(test))]
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

#[cfg(not(test))]
#[rustler::nif(name = "pipe_read_binary", schedule = "DirtyCpu")]
pub fn read_binary(pipe_resource: ResourceArc<PipeResource>) -> String {
    let mut pipe = pipe_resource.pipe.lock().unwrap();
    let mut buffer = String::new();

    (*pipe).read_to_string(&mut buffer).unwrap();
    buffer
}

#[cfg(not(test))]
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

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::AsyncWriteExt;

    #[test]
    fn default_limit_rejects_sparse_extension_without_allocating() {
        let mut pipe = Pipe::new();
        assert_eq!(pipe.max_size, DEFAULT_MAX_SIZE);
        pipe.seek(io::SeekFrom::Start(DEFAULT_MAX_SIZE as u64))
            .unwrap();
        assert!(pipe.write(b"x").is_err());
        assert_eq!(pipe.size(), 0);
        assert_eq!(pipe.borrow().get_ref().capacity(), 0);
    }

    #[test]
    fn rejects_full_write_without_changing_bytes_or_shared_cursor() {
        let mut pipe = Pipe::with_max_size(5);
        let mut clone = pipe.clone();
        assert_eq!(pipe.write(b"hello").unwrap(), 5);
        clone.seek(io::SeekFrom::Start(4)).unwrap();
        assert!(clone.write(b"xy").is_err());
        assert_eq!(pipe.borrow().position(), 4);
        assert_eq!(pipe.borrow().get_ref(), b"hello");
        assert_eq!(pipe.write(b"!").unwrap(), 1);
        assert_eq!(clone.borrow().get_ref(), b"hell!");
    }

    #[test]
    fn reads_retain_bytes_and_overwrites_still_work_at_limit() {
        let mut pipe = Pipe::with_max_size(5);
        pipe.write_all(b"hello").unwrap();
        pipe.seek(io::SeekFrom::Start(0)).unwrap();
        let mut bytes = Vec::new();
        pipe.read_to_end(&mut bytes).unwrap();
        assert_eq!(bytes, b"hello");
        assert!(pipe.write(b"!").is_err());
        assert_eq!(pipe.size(), 5);
        pipe.seek(io::SeekFrom::Start(1)).unwrap();
        pipe.write_all(b"a").unwrap();
        assert_eq!(pipe.borrow().get_ref(), b"hallo");
        assert_eq!(pipe.borrow().position(), 2);
    }

    #[test]
    fn sparse_writes_preserve_gaps_within_limit() {
        let mut pipe = Pipe::with_max_size(4);
        pipe.seek(io::SeekFrom::Start(3)).unwrap();
        assert_eq!(pipe.write(b"x").unwrap(), 1);
        assert_eq!(pipe.borrow().get_ref(), b"\0\0\0x");
        assert!(pipe.write(b"x").is_err());
        assert_eq!(pipe.size(), 4);
    }

    #[test]
    fn huge_positions_and_allocation_failures_leave_pipe_unchanged() {
        let mut pipe = Pipe::with_max_size(usize::MAX);
        pipe.seek(io::SeekFrom::Start(u64::MAX)).unwrap();
        assert!(pipe.write(b"x").is_err());
        assert_eq!(pipe.borrow().position(), u64::MAX);
        assert_eq!(pipe.size(), 0);
        pipe.seek(io::SeekFrom::Start((usize::MAX - 1) as u64))
            .unwrap();
        assert!(pipe.write(b"x").is_err());
        assert_eq!(pipe.borrow().position(), (usize::MAX - 1) as u64);
        assert_eq!(pipe.size(), 0);
    }

    #[test]
    fn empty_writes_cannot_allocate_past_limit() {
        let mut pipe = Pipe::with_max_size(0);
        assert_eq!(pipe.write(b"").unwrap(), 0);
        assert!(pipe.write(b"x").is_err());
        pipe.seek(io::SeekFrom::Start(u64::MAX)).unwrap();
        assert!(pipe.write(b"").is_err());
        assert_eq!(pipe.size(), 0);
    }

    #[tokio::test]
    async fn wasi_stdout_streams_share_the_limit_and_report_errors() {
        let pipe = Pipe::with_max_size(4);
        let mut stdout = StdoutStream::async_stream(&pipe);
        let mut stderr = StdoutStream::async_stream(&pipe);
        stdout.write_all(b"ab").await.unwrap();
        stderr.write_all(b"cd").await.unwrap();
        assert!(stdout.write_all(b"e").await.is_err());
        assert!(stderr.write_all(b"f").await.is_err());
        assert_eq!(pipe.size(), 4);
        assert_eq!(pipe.borrow().get_ref(), b"abcd");
        assert_eq!(pipe.borrow().position(), 4);
    }
}
