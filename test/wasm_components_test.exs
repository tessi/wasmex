defmodule Wasmex.WasmComponentsTest do
  use ExUnit.Case, async: true

  alias Wasmex.Engine
  alias Wasmex.EngineConfig

  test "invoke component func" do
    {:ok, store} = Wasmex.Store.new_wasi(%Wasmex.Wasi.WasiOptions{})
    assert [first, second] = Wasmex.Native.todo_init(store.resource)
    assert second =~ "Codebeam"
  end
end
