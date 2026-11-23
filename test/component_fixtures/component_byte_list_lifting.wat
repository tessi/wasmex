(component
  (type $bytes (list u8))
  (type $byte-result (result $bytes (error string)))
  (import "consume" (func $consume (param "bytes" $bytes) (result u32)))
  (import "notify" (func $notify (param "bytes" $bytes)))
  (core module $mem
    (memory (export "memory") 129)
    (func (export "realloc") (param i32 i32 i32 i32) (result i32) i32.const 64))
  (core instance $mem (instantiate $mem))
  (alias core export $mem "memory" (core memory $memory))
  (alias core export $mem "realloc" (core func $realloc))
  (core func $consume (canon lower (func $consume) (memory $memory)))
  (core func $notify (canon lower (func $notify) (memory $memory)))
  (core module $guest
    (import "env" "memory" (memory 129))
    (import "env" "consume" (func $consume (param i32 i32) (result i32)))
    (import "env" "notify" (func $notify (param i32 i32)))
    (func $fill (param $len i32)
      i32.const 1024 i32.const 171 local.get $len memory.fill)
    (func $read (export "read") (param $len i32) (result i32)
      local.get $len call $fill
      i32.const 0 i32.const 1024 i32.store
      i32.const 4 local.get $len i32.store
      i32.const 0)
    (func (export "read-empty") (result i32)
      i32.const 0 call $read)
    (func (export "read-string") (param i32) (param $len i32) (result i32)
      local.get $len call $read)
    (func (export "read-result") (param $len i32) (param i32 i32) (result i32)
      local.get $len call $fill
      i32.const 16 i32.const 0 i32.store
      i32.const 20 i32.const 1024 i32.store
      i32.const 24 local.get $len i32.store
      i32.const 16)
    (func (export "call-consume") (param $len i32) (result i32)
      local.get $len call $fill
      i32.const 1024 local.get $len call $consume
      i32.const 1024 i32.const 0 local.get $len memory.fill)
    (func (export "call-notify") (param $len i32)
      local.get $len call $fill
      i32.const 1024 local.get $len call $notify)
    (func (export "call-invalid-pointer") (result i32)
      i32.const -1 i32.const 1 call $consume)
    (func (export "post-read") (param i32)
      i32.const 1024 i32.const 0 i32.store8))
  (core instance $guest (instantiate $guest (with "env" (instance
    (export "memory" (memory $memory))
    (export "consume" (func $consume))
    (export "notify" (func $notify))))))
  (alias core export $guest "post-read" (core func $post-read))
  (func (export "read") (param "length" u32) (result $bytes)
    (canon lift (core func $guest "read") (memory $memory) (post-return $post-read)))
  (func (export "read-empty") (result $bytes)
    (canon lift (core func $guest "read-empty") (memory $memory)))
  (func (export "read-string") (param "text" string) (result $bytes)
    (canon lift (core func $guest "read-string") (memory $memory) (realloc $realloc)))
  (func (export "read-result") (param "length" u32) (param "label" string) (result $byte-result)
    (canon lift (core func $guest "read-result") (memory $memory) (realloc $realloc)))
  (func (export "call-consume") (param "length" u32) (result u32)
    (canon lift (core func $guest "call-consume")))
  (func (export "call-notify") (param "length" u32)
    (canon lift (core func $guest "call-notify")))
  (func (export "call-invalid-pointer") (result u32)
    (canon lift (core func $guest "call-invalid-pointer"))))
