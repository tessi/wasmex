(component
  (type $bytes (list u8))
  (import "store" (instance $store
    (export "lookup" (func (param "key" string) (result (list u8))))
    (export "default" (func (result (list u8))))))
  (core module $mem
    (memory (export "memory") 1)
    (data (i32.const 32) "key")
    (func (export "realloc") (param i32 i32 i32 i32) (result i32) i32.const 128))
  (core instance $mem (instantiate $mem))
  (alias core export $mem "memory" (core memory $memory))
  (alias core export $mem "realloc" (core func $realloc))
  (core func $lookup (canon lower (func $store "lookup") (memory $memory) (realloc $realloc)))
  (core func $default (canon lower (func $store "default") (memory $memory) (realloc $realloc)))
  (core module $guest
    (import "" "lookup" (func $lookup (param i32 i32 i32)))
    (import "" "default" (func $default (param i32)))
    (func (export "lookup") (result i32)
      i32.const 32 i32.const 3 i32.const 16 call $lookup i32.const 16)
    (func (export "default") (result i32)
      i32.const 16 call $default i32.const 16))
  (core instance $guest (instantiate $guest (with "" (instance
    (export "lookup" (func $lookup)) (export "default" (func $default))))))
  (func (export "lookup") (result $bytes) (canon lift (core func $guest "lookup") (memory $memory)))
  (func (export "default") (result $bytes) (canon lift (core func $guest "default") (memory $memory))))
