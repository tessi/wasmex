defmodule Wasmex.InstanceTest do
  use ExUnit.Case, async: true
  doctest Wasmex.Instance

  defp build_wasm_instance do
    bytes = File.read!(TestHelper.wasm_file_path)
    Wasmex.Instance.from_bytes(bytes)
  end

  describe "from_bytes/1" do
    test "instantiates an Instance from a valid wasm file" do
      bytes = File.read!(TestHelper.wasm_file_path)
      {:ok, _} = Wasmex.Instance.from_bytes(bytes)
    end
  end

  describe "function_export_exists/2" do
    test "returns whether a function export could be found in the wasm file" do
      {:ok, instance} = build_wasm_instance()
      assert Wasmex.Instance.function_export_exists(instance, "sum")
      refute Wasmex.Instance.function_export_exists(instance, "sum42") # 🎸
    end
  end

  describe "call_exported_function/2" do
    test "runs functions which return an integer" do
      {:ok, instance} = build_wasm_instance()
      assert 42 == Wasmex.Instance.call_exported_function(instance, "arity_0")
    end
  end

  describe "call_exported_function/3" do
    test "runs functions without params" do
      {:ok, instance} = build_wasm_instance()
      assert 42 == Wasmex.Instance.call_exported_function(instance, "arity_0", [])
    end
  end
end
