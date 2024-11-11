defmodule Wasmex.WasmComponentsTest do
  use ExUnit.Case, async: true

  alias Wasmex.Engine
  alias Wasmex.EngineConfig

  test "invoke component func" do
    {:ok, store} = Wasmex.ComponentStore.new(%Wasmex.Wasi.WasiOptions{})
    component_bytes = File.read!("test/support/hello_world/hello_world.wasm")
    {:ok, component} = Wasmex.Component.new(store, component_bytes)
    IO.inspect("building instance")
    {:ok, instance} = Wasmex.Component.Instance.new(store, component)
    IO.inspect("executing component function")

    assert {:ok, "Hello, Elixir!"} =
             Wasmex.Component.Instance.call_function(instance, "greet", ["Elixir"])

    #  |> IO.inspect()
  end
end
