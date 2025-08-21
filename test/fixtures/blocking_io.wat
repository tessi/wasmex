(module
  ;; Import a host function that simulates blocking I/O (sleep)
  (import "env" "sleep_ms" (func $sleep_ms (param i32)))
  
  ;; Import a host function for CPU-intensive work
  (import "env" "compute" (func $compute (param i32) (result i32)))
  
  ;; Memory for data operations
  (memory 1)
  (export "memory" (memory 0))
  
  ;; Function that simulates blocking I/O operation
  (func $blocking_io (export "blocking_io") (param $ms i32)
    (call $sleep_ms (local.get $ms))
  )
  
  ;; Function that does some computation then blocks
  (func $mixed_workload (export "mixed_workload") (param $iterations i32) (param $sleep_ms i32) (result i32)
    (local $result i32)
    (local $i i32)
    
    ;; Do some computation
    (local.set $i (i32.const 0))
    (local.set $result (i32.const 0))
    (loop $compute_loop
      (local.set $result 
        (i32.add (local.get $result) 
                 (call $compute (local.get $i))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $compute_loop (i32.lt_u (local.get $i) (local.get $iterations)))
    )
    
    ;; Then block
    (call $sleep_ms (local.get $sleep_ms))
    
    ;; Return result
    (local.get $result)
  )
  
  ;; Pure CPU-intensive function
  (func $cpu_intensive (export "cpu_intensive") (param $n i32) (result i32)
    (local $result i32)
    (local $i i32)
    
    (local.set $result (i32.const 1))
    (local.set $i (i32.const 2))
    
    ;; Calculate factorial
    (loop $factorial_loop
      (local.set $result (i32.mul (local.get $result) (local.get $i)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $factorial_loop (i32.le_u (local.get $i) (local.get $n)))
    )
    
    (local.get $result)
  )
  
  ;; Quick function for baseline testing
  (func $quick_function (export "quick_function") (result i32)
    (i32.const 42)
  )
)