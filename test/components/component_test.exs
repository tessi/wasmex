defmodule Wasmex.WasmComponentsTest do
  use ExUnit.Case, async: true

  alias Wasmex.Engine
  alias Wasmex.EngineConfig

  test "invoke component func" do
    {:ok, store} = Wasmex.Components.Store.new_wasi()
    component_bytes = File.read!("test/component_fixtures/hello_world/hello_world.wasm")
    {:ok, component} = Wasmex.Components.Component.new(store, component_bytes)
    {:ok, instance} = Wasmex.Components.Instance.new(store, component)

    assert {:ok, "Hello, Elixir!"} =
             Wasmex.Components.Instance.call_function(instance, "greet", ["Elixir"])

    assert {:ok, ["Hello, Elixir!", "Hello, Elixir!"]} =
             Wasmex.Components.Instance.call_function(instance, "multi-greet", ["Elixir", 2])
  end

  describe "error handling" do
    setup do
      {:ok, store} =
        Wasmex.Components.Store.new_wasi(%Wasmex.Wasi.WasiP2Options{inherit_stdout: true})

      component_bytes = File.read!("test/component_fixtures/hello_world/hello_world.wasm")
      {:ok, component} = Wasmex.Components.Component.new(store, component_bytes)
      {:ok, instance} = Wasmex.Components.Instance.new(store, component)
      %{instance: instance}
    end

    test "function not exported", %{instance: instance} do
      assert {:error, error} =
               Wasmex.Components.Instance.call_function(instance, "garbage", [:wut])

      assert error =~ "garbage not exported"
    end

    test "invalid arguments", %{instance: instance} do
      assert {:error, _error} = Wasmex.Components.Instance.call_function(instance, "greet", [1])
    end
  end
end
