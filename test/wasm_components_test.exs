defmodule Wasmex.WasmComponentsTest do
  use ExUnit.Case, async: true

  alias Wasmex.Engine
  alias Wasmex.EngineConfig

  test "invoke component func" do
    {:ok, store} = Wasmex.Store.new_wasi(%Wasmex.Wasi.WasiOptions{})
    component_bytes = File.read!("./todo-list.wasm")
    IO.inspect("building component")
    {:ok, component} = Wasmex.Component.new(store, component_bytes)
    IO.inspect("building instance")
    {:ok, instance} = Wasmex.Component.Instance.new(store, component)
    IO.inspect("executing component function")
    assert [first, second] = Wasmex.Native.exec_func(store.resource, instance.resource, "init")
    assert second =~ "Codebeam"
  end
end
