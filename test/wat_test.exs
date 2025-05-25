defmodule WatTest do
  use ExUnit.Case, async: true

  test "converting a Wasm text file to a Wasm core module" do
    wat = """
    (module
      (func (export "add") (param i32) (param i32) (result i32)
        local.get 0
        local.get 1
        i32.add
        return
      )
    )
    """

    assert {:ok, wasm} = Wasmex.Wat.to_wasm(wat)
    assert {:ok, pid} = Wasmex.start_link(%{bytes: wasm})
    assert {:ok, [42]} = Wasmex.call_function(pid, "add", [50, -8])
  end

  test "compile error" do
    wat = "not a wat file"
    assert {:error, error} = Wasmex.Wat.to_wasm(wat)

    assert error ==
             "Failed to parse WAT: expected `(`\n     --> <anon>:1:1\n      |\n    1 | not a wat file\n      | ^"
  end

  test "converting a Wasm text file to a Wasm component" do
    wat = """
    (component
      (core module $LengthCoreWasm
        (func (export "length") (param $ptr i32) (param $len i32) (result i32)
          local.get $len
        )
        (memory (export "mem") 1)
        (func (export "realloc") (param i32 i32 i32 i32) (result i32)
          i32.const 0
        )
      )
      (core instance $length_instance (instantiate $LengthCoreWasm))
      (func (export "length") (param "input" string) (result u32)
        (canon lift
          (core func $length_instance "length")
          (memory $length_instance "mem")
          (realloc (func $length_instance "realloc"))
        )
      )
    )
    """

    assert {:ok, wasm} = Wasmex.Wat.to_wasm(wat)
    assert {:ok, pid} = Wasmex.Components.start_link(%{bytes: wasm})
    assert {:ok, 9} = Wasmex.Components.call_function(pid, "length", ["hi wasmex"])
  end
end
