defmodule WasmexTest do
  use ExUnit.Case
  doctest Wasmex

  test "greets the world" do
    assert Wasmex.hello() == :world
  end
end
