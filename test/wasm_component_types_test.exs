defmodule WasmComponentTypesTest do
  use ExUnit.Case, async: true

  alias Wasmex.Engine
  alias Wasmex.EngineConfig

  test "mapping all the types" do
    {:ok, store} = Wasmex.ComponentStore.new(%Wasmex.Wasi.WasiP2Options{})
    component_bytes = File.read!("test/support/component_types/component_types.wasm")
    {:ok, component} = Wasmex.Component.new(store, component_bytes)
    {:ok, instance} = Wasmex.Component.Instance.new(store, component)

    assert {:ok, "mom"} = Wasmex.Component.Instance.call_function(instance, "id-string", ["mom"])
    assert {:ok, true} = Wasmex.Component.Instance.call_function(instance, "id-bool", [true])

    # all the integer types
    for type <- ["u8", "u16", "u32", "u64", "s8", "s16", "s32", "s64"] do
      assert {:ok, 7} = Wasmex.Component.Instance.call_function(instance, "id-#{type}", [7])
    end

    # don't love this yet, be nicer to support atom keys
    assert {:ok, %{"x" => 1, "y" => 2}} =
             Wasmex.Component.Instance.call_function(instance, "id-record", [
               %{"x" => 1, "y" => 2}
             ])

    assert {:ok, [1, 2, 3]} =
             Wasmex.Component.Instance.call_function(instance, "id-list", [[1, 2, 3]])

    assert {:ok, {1, "two"}} = Wasmex.Component.Instance.call_function(instance, "id-tuple", [{1, "two"}])
  end
end
