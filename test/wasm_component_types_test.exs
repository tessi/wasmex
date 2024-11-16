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
    assert {:ok, 7} = Wasmex.Component.Instance.call_function(instance, "id-u64", [7])
    assert {:ok, 7} = Wasmex.Component.Instance.call_function(instance, "id-u32", [7])
  end
end
