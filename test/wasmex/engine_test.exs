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
  end
end
