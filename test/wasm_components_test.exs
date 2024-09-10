defmodule Wasmex.WasmComponentsTest do
  use ExUnit.Case, async: true

  alias Wasmex.Engine
  alias Wasmex.EngineConfig

  test "invoke component func" do
    {:ok, engine} = Engine.new(%EngineConfig{})
    assert [first, second] = Wasmex.Native.todo_init(engine.resource)
    assert second =~ "Codebeam"
  end
end
