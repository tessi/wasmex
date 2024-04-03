(module
  (global $meaning_of_life (export "meaning_of_life") i32 (i32.const 42))
  (global (export "count_32") (mut i32) (i32.const -32))
  (global (export "count_64") (mut i64) (i64.const -64))
  (global (export "bad_pi_32") (mut f32) (f32.const 0))
  (global (export "bad_pi_64") (mut f64) (f64.const 0))
)