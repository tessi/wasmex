use std::time::{SystemTime, UNIX_EPOCH};
use std::{env, fs, io};

use rand_core::RngCore;
use wasi_rng::WasiRng;

fn main() {
    let args = env::args().collect::<Vec<String>>();
    match args.get(1).map(|s| s.as_str()) {
        Some("list_files") => list_files(args),
        Some("read_file") => read_file(args),
        Some("write_file") => write_file(args),
        Some("create_file") => create_file(args),
        _ => print_info(args),
    };
}

fn list_files(args: Vec<String>) {
    match args.get(2) {
        Some(dir) => {
            if let Ok(entries) = fs::read_dir(dir) {
                let mut entries = entries
                    .map(|res| res.map(|e| e.path()))
                    .collect::<Result<Vec<_>, io::Error>>()
                    .unwrap();

                // // The order in which `read_dir` returns entries is not guaranteed. Since reproducible
                // // ordering is required the entries are explicitly sorted.
                entries.sort();
                for path in entries {
                    println!("{:?}", path);
                }
            } else {
                println!("Could not find directory {}", dir);
            }
        }
        None => println!("error: needs the directory path as second argument"),
    }
}

fn read_file(args: Vec<String>) {
    match args.get(2) {
        Some(path) => match fs::read(path) {
            Ok(contents) => {
                let contents = String::from_utf8_lossy(&contents);
                println!("{}", contents);
            }
            Err(e) => println!("error: could not read file ({:?})", e),
        },
        None => println!("error: needs the file path as second argument"),
    }
}

fn write_file(args: Vec<String>) {
    match args.get(2) {
        Some(path) => match fs::write(path, "Hello, updated world!") {
            Ok(_) => (),
            Err(e) => println!("error: could not write file ({:?})", e),
        },
        None => println!("error: needs the file path as second argument"),
    }
}

fn create_file(args: Vec<String>) {
    match args.get(2) {
        Some(path) => match fs::write(path, "Hello, created world!") {
            Ok(_) => (),
            Err(e) => println!("error: could not write file ({:?})", e),
        },
        None => println!("error: needs the file path as second argument"),
    }
}

fn print_info(args: Vec<String>) {
    println!("Hello from the WASI test program!");
    println!();
    println!("Arguments:");
    for arg in args {
        println!("{}", arg);
    }
    println!();
    println!("Environment:");
    for (name, value) in env::vars().collect::<Vec<(String, String)>>() {
        println!("{}={}", name, value);
    }
    println!();
    println!("Current Time (Since Unix Epoch):");
    let seconds_since_epoch = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("Time went backwards!")
        .as_secs();
    println!("{}", seconds_since_epoch);
    println!();
    let mut rng = WasiRng;
    println!("Random Number: {}", rng.next_u32());
    println!();
}
