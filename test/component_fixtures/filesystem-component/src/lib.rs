#![cfg(target_os = "wasi")]

use std::fs::{File, OpenOptions, read_dir, remove_file};
use std::io::{Read, Write, Seek, SeekFrom};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

wit_bindgen::generate!({
    path: "wit",
    world: "filesystem-test",
});

use crate::exports::test::filesystem::types::{
    Guest as TypesGuest, GuestDirectory, GuestFileHandle, FileHandle, Directory,
};

struct Component;

pub struct MyFileHandle {
    file: Arc<Mutex<File>>,
    path: String,
}

pub struct MyDirectory {
    path: PathBuf,
}

impl GuestFileHandle for MyFileHandle {
    fn read(&self, length: u32) -> Result<Vec<u8>, String> {
        let mut file = self.file.lock().map_err(|e| e.to_string())?;
        let mut buffer = vec![0u8; length as usize];
        let bytes_read = file.read(&mut buffer).map_err(|e| format!("Read failed: {}", e))?;
        buffer.truncate(bytes_read);
        Ok(buffer)
    }

    fn write(&self, data: Vec<u8>) -> Result<u32, String> {
        let mut file = self.file.lock().map_err(|e| e.to_string())?;
        let written = file.write(&data).map_err(|e| format!("Write failed: {}", e))?;
        file.flush().map_err(|e| format!("Flush failed: {}", e))?;
        Ok(written as u32)
    }

    fn seek(&self, offset: u64) -> Result<u64, String> {
        let mut file = self.file.lock().map_err(|e| e.to_string())?;
        let new_pos = file.seek(SeekFrom::Start(offset))
            .map_err(|e| format!("Seek failed: {}", e))?;
        Ok(new_pos)
    }

    fn close(&self) {
        // File will be closed when dropped
    }
}

impl GuestDirectory for MyDirectory {
    fn open_file(&self, path: String) -> Result<FileHandle, String> {
        let full_path = self.path.join(&path);
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .open(&full_path)
            .map_err(|e| format!("Open failed for {:?}: {}", full_path, e))?;

        Ok(FileHandle::new(MyFileHandle {
            file: Arc::new(Mutex::new(file)),
            path: path.clone(),
        }))
    }

    fn create_file(&self, path: String) -> Result<FileHandle, String> {
        let full_path = self.path.join(&path);
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(true)
            .open(&full_path)
            .map_err(|e| format!("Create failed for {:?}: {}", full_path, e))?;

        Ok(FileHandle::new(MyFileHandle {
            file: Arc::new(Mutex::new(file)),
            path: path.clone(),
        }))
    }

    fn list_entries(&self) -> Result<Vec<String>, String> {
        let entries = read_dir(&self.path)
            .map_err(|e| format!("List failed for {:?}: {}", self.path, e))?;
        
        let mut names = Vec::new();
        for entry in entries {
            let entry = entry.map_err(|e| format!("Read entry failed: {}", e))?;
            if let Some(name) = entry.file_name().to_str() {
                names.push(name.to_string());
            }
        }
        Ok(names)
    }

    fn delete_file(&self, path: String) -> Result<(), String> {
        let full_path = self.path.join(&path);
        remove_file(&full_path)
            .map_err(|e| format!("Delete failed for {:?}: {}", full_path, e))
    }
}

impl TypesGuest for Component {
    type FileHandle = MyFileHandle;
    type Directory = MyDirectory;
    
    fn open_directory(path: String) -> Result<Directory, String> {
        // In WASI with our fixed implementation, preopened directories 
        // are mapped to their base names (e.g., /tmp/foo/input -> "input")
        // The guest should pass the mapped name directly
        
        // Use the path as-is since it should already be the correct guest path
        let path_buf = PathBuf::from(&path);
        
        // Return the directory handle - operations will fail if the path is invalid
        Ok(Directory::new(MyDirectory {
            path: path_buf,
        }))
    }
}

export!(Component);