//! A Pipe is a file buffer hold in memory.
//! It can, for example, be used to replace stdin/stdout/stderr of a WASI module.

use std::any::Any;
use std::io::{self, Read, Seek};
use std::io::{Cursor, Write};
use std::sync::{Arc, Mutex, RwLock};

use rustler::resource::ResourceArc;
use rustler::{Encoder, Term};

use wasi_common::file::{FdFlags, FileType};
use wasi_common::Error;
use wasi_common::WasiFile;

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
    fn borrow(&self) -> std::sync::RwLockWriteGuard<Cursor<Vec<u8>>> {
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

#[wiggle::async_trait]
impl WasiFile for Pipe {
    fn as_any(&self) -> &dyn Any {
        self
    }

    async fn get_filetype(&mut self) -> Result<FileType, Error> {
        Ok(FileType::Unknown)
    }

    async fn get_fdflags(&mut self) -> Result<FdFlags, Error> {
        Ok(FdFlags::APPEND)
    }

    async fn write_vectored<'a>(&mut self, bufs: &[io::IoSlice<'a>]) -> Result<u64, Error> {
        let buffer = &mut *(self.borrow());
        buffer
            .write_vectored(bufs)
            .map(|written| written as u64)
            .map_err(wasi_common::Error::from)
    }

    async fn read_vectored<'a>(&mut self, bufs: &mut [io::IoSliceMut<'a>]) -> Result<u64, Error> {
        let buffer = &mut *(self.borrow());
        buffer
            .read_vectored(bufs)
            .map(|read| read as u64)
            .map_err(wasi_common::Error::from)
    }

    fn isatty(&mut self) -> bool {
        false
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
pub fn size(pipe_resource: ResourceArc<PipeResource>) -> u64 {
    let pipe: &Pipe = &pipe_resource.pipe.lock().unwrap();
    pipe.size()
}

#[rustler::nif(name = "pipe_seek")]
pub fn seek(pipe_resource: ResourceArc<PipeResource>, pos: u64) -> rustler::NifResult<u64> {
    let pipe: &mut Pipe = &mut pipe_resource.pipe.lock().unwrap();

    Seek::seek(pipe, io::SeekFrom::Start(pos))
        .map_err(|err| rustler::Error::Term(Box::new(err.to_string())))
}

#[rustler::nif(name = "pipe_read_binary")]
pub fn read_binary(pipe_resource: ResourceArc<PipeResource>) -> String {
    let mut pipe = pipe_resource.pipe.lock().unwrap();
    let mut buffer = String::new();

    (*pipe).read_to_string(&mut buffer).unwrap();
    buffer
}

#[rustler::nif(name = "pipe_write_binary")]
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
