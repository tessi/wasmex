use std::env;
use std::time::{SystemTime, UNIX_EPOCH};

use rand_core::RngCore;
use wasi_rng::WasiRng;

fn main() {
    println!("Hello from the WASI test program!");
    println!();

    println!("Arguments:");
    for arg in env::args().collect::<Vec<String>>() {
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
