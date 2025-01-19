defmodule Wasmex.WasmComponentsTest do
  use ExUnit.Case, async: true

  alias Wasmex.Wasi.WasiP2Options

  describe "error handling" do
    setup do
      component_bytes = File.read!("test/component_fixtures/hello_world/hello_world.wasm")

      instance =
        start_supervised!({HelloWorld, bytes: component_bytes, wasi: %WasiP2Options{}})

      %{instance: instance}
    end

    test "function not exported", %{instance: instance} do
      assert {:error, error} =
               Wasmex.Components.call_function(instance, "garbage", [:wut])

      assert error =~ "exported function `garbage` not found"
    end

    test "invalid arguments", %{instance: instance} do
      assert {:error, error} = Wasmex.Components.call_function(instance, "greet", [1])
      assert error =~ "Could not convert Integer to String"
    end
  end
end
