(module
  ;; Define memory with 1 initial page (64KB)
  (memory $mem (export "memory") 1)
  
  ;; Initialize memory with some data
  (data (i32.const 0) "Hello, Async Wasmex!")
  
  ;; Function to write a byte to memory
  (func $write_byte (export "write_byte") (param $offset i32) (param $value i32)
    local.get $offset
    local.get $value
    i32.store8)
  
  ;; Function to read a byte from memory
  (func $read_byte (export "read_byte") (param $offset i32) (result i32)
    local.get $offset
    i32.load8_u)
  
  ;; Function to get current memory size in pages
  (func $get_memory_size (export "get_memory_size") (result i32)
    memory.size)
  
  ;; Function to grow memory by n pages
  (func $grow_memory (export "grow_memory") (param $pages i32) (result i32)
    local.get $pages
    memory.grow)
)