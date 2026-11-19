(component
  (type $bytes (list u8))
  (type $count-result (result u32 (error string)))
  (type $read-result (result $bytes (error string)))
  (core module $guest
    (memory (export "memory") 1)
    ;; An error result at 16 and a successful result pointing to bytes at 128.
    (data (i32.const 16) "\01\00\00\00\40\00\00\00\03\00\00\00")
    (data (i32.const 36) "\80\00\00\00")
    (data (i32.const 64) "bad")
    (func (export "realloc") (param i32 i32 i32 i32) (result i32)
      i32.const 8192)
    (func (export "count") (param $ptr i32) (param $len i32) (result i32)
      ;; Return the length plus the last byte to check that the input arrived intact.
      i32.const 4
      local.get $len
      if (result i32)
        local.get $len
        local.get $ptr local.get $len i32.add i32.const 1 i32.sub i32.load8_u
        i32.add
      else
        i32.const 0
      end
      i32.store
      i32.const 0)
    (func (export "read") (param $value i32) (param i32 i32) (result i32)
      local.get $value i32.const 999 i32.eq
      if (result i32)
        i32.const 16
      else
        i32.const 128 local.get $value i32.store8
        i32.const 40
        local.get $value
        if (result i32) i32.const 128 else i32.const 0 end
        i32.store
        i32.const 32
      end)
    (func (export "post-return") (param i32)
      i32.const 128 i32.const 0 i32.store8))
  (core instance $guest (instantiate $guest))
  (alias core export $guest "memory" (core memory $memory))
  (alias core export $guest "realloc" (core func $realloc))
  (alias core export $guest "post-return" (core func $post-return))
  (func (export "count-bytes") (param "data" $bytes) (result $count-result)
    (canon lift (core func $guest "count") (memory $memory) (realloc $realloc)))
  (func (export "read-buffer") (param "value" u32) (param "label" string) (result $read-result)
    (canon lift (core func $guest "read") (memory $memory) (realloc $realloc) (post-return $post-return))))
