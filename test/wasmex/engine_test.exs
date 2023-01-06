defmodule Wasmex.EngineTest do
  use ExUnit.Case, async: true
  import TestHelper, only: [t: 1]

  doctest Wasmex.Engine

  describe t(&Engine.new/1) do
    test "creates a new Engine" do
      assert {:ok, %Wasmex.Engine{}} = Wasmex.Engine.new(%Wasmex.EngineConfig{})
    end
  end

  describe t(&Engine.default/1) do
    test "creates an Engine with default config" do
      assert %Wasmex.Engine{} = Wasmex.Engine.default()
    end
  end

  describe t(&Engine.precompile/2) do
    test "precompiles a module" do
      {:ok, engine} = Wasmex.Engine.new(%Wasmex.EngineConfig{})
      wasm_bytes = File.read!(TestHelper.wasm_test_file_path())

      assert {:ok, serialized_module} = Wasmex.Engine.precompile_module(engine, wasm_bytes)
      assert is_binary(serialized_module)

      {:ok, deserialized_module} = Wasmex.Module.unsafe_deserialize(serialized_module)
      %{module: module} = TestHelper.wasm_module()

      assert Wasmex.Module.exports(module) == Wasmex.Module.exports(deserialized_module)
    end
  end
end
