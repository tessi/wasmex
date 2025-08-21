(module
  ;; Fibonacci function - deliberately inefficient recursive implementation
  (func $fib (export "fib") (param $n i32) (result i32)
    (if (result i32)
      (i32.le_s (local.get $n) (i32.const 1))
      (then (local.get $n))
      (else
        (i32.add
          (call $fib (i32.sub (local.get $n) (i32.const 1)))
          (call $fib (i32.sub (local.get $n) (i32.const 2)))
        )
      )
    )
  )
  
  ;; Prime check - deliberately inefficient
  (func $is_prime (export "is_prime") (param $n i32) (result i32)
    (local $i i32)
    (local $limit i32)
    
    (if (i32.le_s (local.get $n) (i32.const 1))
      (then (return (i32.const 0)))
    )
    
    (if (i32.eq (local.get $n) (i32.const 2))
      (then (return (i32.const 1)))
    )
    
    (local.set $limit (local.get $n))
    (local.set $i (i32.const 2))
    
    (loop $check
      (if (i32.eq (i32.rem_s (local.get $n) (local.get $i)) (i32.const 0))
        (then (return (i32.const 0)))
      )
      
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      
      (if (i32.lt_s (local.get $i) (local.get $limit))
        (then (br $check))
      )
    )
    
    (i32.const 1)
  )
  
  ;; CPU-intensive loop
  (func $cpu_burn (export "cpu_burn") (param $iterations i32) (result i32)
    (local $i i32)
    (local $sum i32)
    
    (local.set $i (i32.const 0))
    (local.set $sum (i32.const 0))
    
    (loop $burn
      (local.set $sum 
        (i32.add (local.get $sum)
          (i32.mul (local.get $i) (local.get $i))
        )
      )
      
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      
      (if (i32.lt_s (local.get $i) (local.get $iterations))
        (then (br $burn))
      )
    )
    
    (local.get $sum)
  )
)