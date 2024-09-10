defmodule Wasmex.WasmComponentsTest do
  use ExUnit.Case, async: true

  alias Wasmex.Engine
  alias Wasmex.EngineConfig

  test "invoke component func" do
    engine = Engine.default()
    assert [first, second] = Wasmex.Native.todo_init(engine.resource)
    assert second =~ "Codebeam"
  end
end
