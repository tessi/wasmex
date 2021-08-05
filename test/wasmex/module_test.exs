defmodule Wasmex.ModuleTest do
  use ExUnit.Case, async: true
  doctest Wasmex.Module

  @wat """
  (module
    (type $add_one_t (func (param i32) (result i32)))
    (func $add_one_f (type $add_one_t) (param $value i32) (result i32)
      local.get $value
      i32.const 1
      i32.add)
    (export "add_one" (func $add_one_f)))
  """

  describe "module compilation from WAT" do
    test "instantiates a simple module from wat" do
      {:ok, module} = Wasmex.Module.compile(@wat)
      instance = start_supervised!({Wasmex, %{module: module}})
      assert {:ok, [42]} == Wasmex.call_function(instance, :add_one, [41])
    end

    test "errors when attempting to compile nonsense" do
      wat = "wat is this? not WAT for sure"

      assert {:error,
              "Error while parsing bytes: expected `(`\n     --> <anon>:1:1\n      |\n    1 | wat is this? not WAT for sure\n      | ^."} ==
               Wasmex.Module.compile(wat)
    end
  end

  describe "module de-/serialization" do
    test "a module can be serialized and deserialized again" do
      module = TestHelper.wasm_module()
      {:ok, serialized} = Wasmex.Module.serialize(module)
      {:ok, deserialized_module} = Wasmex.Module.unsafe_deserialize(serialized)
      instance = start_supervised!({Wasmex, %{module: deserialized_module}})
      assert Wasmex.function_exists(instance, :arity_0)
    end
  end

  describe "name and set_name" do
    test "a modules name can be set and read out" do
      {:ok, module} = Wasmex.Module.compile(@wat)
      assert nil == Wasmex.Module.name(module)
      :ok = Wasmex.Module.set_name(module, "test name")
      assert "test name" == Wasmex.Module.name(module)
    end
  end
end
