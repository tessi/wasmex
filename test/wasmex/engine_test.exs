defmodule Wasmex.EngineTest do
  use ExUnit.Case, async: true
  import TestHelper, only: [t: 1]

  alias Wasmex.Engine
  alias Wasmex.EngineConfig
  alias Wasmex.Module

  doctest Engine

  describe t(&Engine.new/1) do
    test "creates a new Engine" do
      assert {:ok, %Engine{}} = Engine.new(%EngineConfig{})
    end

    test "accepts configurations created before the tuning fields were added" do
      config =
        Map.drop(%EngineConfig{}, [
          :parallel_compilation,
          :memory_reservation,
          :memory_guard_size,
          :memory_init_cow
        ])

      assert {:ok, %Engine{}} = Engine.new(config)
    end

    test "rejects invalid engine tuning values" do
      for {field, value} <- [
            parallel_compilation: :yes,
            memory_reservation: -1,
            memory_guard_size: 1.5,
            memory_init_cow: 1
          ] do
        config = struct!(EngineConfig, [{field, value}])
        assert catch_error(Engine.new(config)) =~ "Could not decode field :#{field}"
      end
    end
  end

  describe t(&Engine.default/1) do
    test "creates an Engine with default config" do
      assert %Engine{} = Engine.default()
    end

    test "creates an Engine with a changed config" do
      assert {:ok, %Engine{}} =
               %EngineConfig{}
               |> EngineConfig.consume_fuel(true)
               |> EngineConfig.cranelift_opt_level(:speed)
               |> EngineConfig.memory64(true)
               |> Engine.new()
    end
  end

  describe t(&Engine.precompile/2) do
    test "precompiles a module" do
      {:ok, engine} = Engine.new(%EngineConfig{})
      wasm_bytes = File.read!(TestHelper.wasm_test_file_path())

      assert {:ok, serialized_module} = Engine.precompile_module(engine, wasm_bytes)
      assert is_binary(serialized_module)

      {:ok, deserialized_module} = Module.unsafe_deserialize(serialized_module)
      %{module: module} = TestHelper.wasm_module()

      assert Module.exports(module) == Module.exports(deserialized_module)
    end

    test "precompiles and runs a module with explicit engine tuning" do
      config = %EngineConfig{
        parallel_compilation: false,
        memory_reservation: 131_072,
        memory_guard_size: 65_536,
        memory_init_cow: false
      }

      wat = """
      (module
        (memory (export "memory") 1)
        (data (i32.const 0) "wasmex"))
      """

      assert {:ok, engine} = Engine.new(config)
      assert {:ok, artifact} = Engine.precompile_module(engine, wat)
      assert {:ok, module} = Module.unsafe_deserialize(artifact, engine)
      assert {:ok, store} = Wasmex.Store.new(nil, engine)
      assert {:ok, instance} = Wasmex.Instance.new(store, module, %{})
      assert {:ok, memory} = Wasmex.Memory.from_instance(store, instance)
      assert Wasmex.Memory.read_binary(store, memory, 0, 6) == "wasmex"

      assert {:ok, incompatible_engine} =
               Engine.new(%{config | memory_guard_size: 131_072})

      assert {:error, reason} = Module.unsafe_deserialize(artifact, incompatible_engine)
      assert reason =~ "memory guard size"
    end
  end
end
