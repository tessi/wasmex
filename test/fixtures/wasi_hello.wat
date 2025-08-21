(module
  ;; Import WASI functions
  (import "wasi_snapshot_preview1" "fd_write" 
    (func $fd_write (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "proc_exit" 
    (func $proc_exit (param i32)))
    
  ;; Memory (required for WASI)
  (memory 1)
  (export "memory" (memory 0))
  
  ;; Data segment with "Hello from WASI!\n"
  (data (i32.const 8) "Hello from WASI!\n")
  
  ;; iovec structure at offset 0
  ;; iov_base = 8 (pointer to string)
  ;; iov_len = 17 (length of string)
  (data (i32.const 0) "\08\00\00\00\11\00\00\00")
  
  ;; Start function (entry point for WASI)
  (func $start (export "_start")
    ;; Write to stdout (fd=1)
    ;; fd=1, iovs=0, iovs_len=1, nwritten=100
    (drop
      (call $fd_write
        (i32.const 1)    ;; stdout
        (i32.const 0)    ;; iovec array at offset 0
        (i32.const 1)    ;; 1 iovec
        (i32.const 100)  ;; where to store bytes written
      )
    )
    
    ;; Exit with code 0
    (call $proc_exit (i32.const 0))
  )
)