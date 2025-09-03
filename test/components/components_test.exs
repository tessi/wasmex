defmodule Wasmex.Components.ComponentsTest do
  use ExUnit.Case, async: true

  alias Wasmex.EngineConfig
  alias Wasmex.Wasi.WasiP2Options

  test "bring your own store with debug info enabled" do
    {:ok, engine} = Wasmex.Engine.new(%EngineConfig{debug_info: true})

    {:ok, store} =
      Wasmex.Components.Store.new_wasi(
        %WasiP2Options{allow_http: true},
        %Wasmex.StoreLimits{},
        engine
      )

    component_bytes = File.read!("test/component_fixtures/hello_world/hello_world.wasm")

    instance =
      start_supervised!({HelloWorld, bytes: component_bytes, store: store})

    assert {:ok, greeting} = Wasmex.Components.call_function(instance, "greet", ["World"])
    assert greeting =~ "Hello"
  end

  describe "error handling" do
    setup do
      component_bytes = File.read!("test/component_fixtures/hello_world/hello_world.wasm")

      instance =
        start_supervised!(
          {HelloWorld, bytes: component_bytes, wasi: %WasiP2Options{allow_http: true}}
        )

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

  describe "setting debug info" do
    test "with debug info" do
      component_pid =
        start_supervised!(
          {Wasmex.Components,
           path: "test/component_fixtures/hello_world/hello_world.wasm",
           wasi: %WasiP2Options{allow_http: true},
           imports: %{
             "greeter" => {:fn, fn -> "Space" end}
           },
           engine_config: %EngineConfig{debug_info: true}}
        )

      assert {:ok, "Hello, World from Space!"} =
               Wasmex.Components.call_function(component_pid, "greet", ["World"])
    end
  end
end
