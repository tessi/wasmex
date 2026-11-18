defmodule Wasmex.WasmComponentsTest do
  use ExUnit.Case, async: true

  alias Wasmex.Components.{Component, Store}
  alias Wasmex.{Engine, EngineConfig}
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

  describe "precompiled components" do
    setup do
      %{bytes: File.read!("test/component_fixtures/hello_world/hello_world.wasm")}
    end

    test "starts independent stores from an AOT artifact with per-instance imports", %{
      bytes: bytes
    } do
      assert {:ok, artifact} = Engine.precompile_component(Engine.default(), bytes)
      engine = Engine.default()
      assert {:ok, component} = Component.unsafe_deserialize(artifact, engine)

      for origin <- ["Space", "Earth"] do
        assert {:ok, store} = Store.new_wasi(%WasiP2Options{allow_http: true}, nil, engine)

        pid =
          start_supervised!(
            {Wasmex.Components,
             %{
               component: component,
               store: store,
               imports: %{"greeter" => {:fn, fn -> origin end}}
             }},
            id: origin
          )

        expected = "Hello, World from #{origin}!"

        assert {:ok, ^expected} =
                 Wasmex.Components.call_function(pid, "greet", ["World"])
      end
    end

    test "serializes a compiled component and starts a ComponentServer from it", %{bytes: bytes} do
      engine = Engine.default()
      assert {:ok, store} = Store.new_wasi(%WasiP2Options{allow_http: true}, nil, engine)
      assert {:ok, compiled} = Component.new(store, bytes)
      assert {:ok, artifact} = Component.serialize(compiled)
      assert {:error, _} = Component.new(store, artifact)
      assert {:ok, loaded} = Component.unsafe_deserialize(artifact, engine)

      pid = start_supervised!({HelloWorld, component: loaded, store: store})

      assert {:ok, "Hello, World from a function defined in the module!"} =
               HelloWorld.greet(pid, "World")
    end

    test "requires an explicit store and a single component source" do
      engine = Engine.default()
      assert {:ok, artifact} = Engine.precompile_component(engine, "(component)")
      assert {:ok, component} = Component.unsafe_deserialize(artifact, engine)
      assert {:ok, store} = Store.new(nil, engine)

      assert {:error, :must_specify_store_for_component} =
               Wasmex.Components.start_link(component: component)

      assert {:error, :conflicting_component_sources} =
               Wasmex.Components.start_link(component: component, store: store, bytes: artifact)

      assert {:error, :conflicting_component_sources} =
               Wasmex.Components.start_link(
                 component: component,
                 store: store,
                 path: "unused.wasm"
               )

      assert {:error, :invalid_component} =
               Wasmex.Components.start_link(component: artifact, store: store)
    end

    test "rejects core modules and incompatible engines" do
      engine = Engine.default()
      assert {:error, _} = Engine.precompile_component(engine, "(module)")
      assert {:ok, artifact} = Engine.precompile_component(engine, "(component)")

      assert {:ok, fuel_engine} = Engine.new(%EngineConfig{consume_fuel: true})
      assert {:error, _} = Component.unsafe_deserialize(artifact, fuel_engine)

      assert {:ok, component} = Component.unsafe_deserialize(artifact, engine)
      assert {:ok, store} = Store.new()

      assert {:error, reason} =
               Wasmex.Components.start_link(component: component, store: store)

      assert reason =~ "cross-`Engine` instantiation is not currently supported"
    end
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
