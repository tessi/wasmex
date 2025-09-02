defmodule Wasmex.InstanceTest do
  use ExUnit.Case, async: false
  import TestHelper, only: [t: 1]

  doctest Wasmex.Instance

  defp build_wasm_instance() do
    %{store: store, module: module} = TestHelper.wasm_module()
    {:ok, instance} = Wasmex.Instance.new(store, module, %{})

    %{store: store, module: module, instance: instance}
  end

  describe t(&Instance.new/2) do
    test "instantiates an Instance from a valid wasm file" do
      %{store: store, module: module} = TestHelper.wasm_module()
      {:ok, _} = Wasmex.Instance.new(store, module, %{})
    end

    test "errors when not providing necessary imports" do
      bytes = File.read!("#{Path.dirname(__ENV__.file)}/../example_wasm_files/simple.wasm")
      {:ok, store} = Wasmex.Store.new()
      {:ok, module} = Wasmex.Module.compile(store, bytes)

      assert {:error, "unknown import: `imports::imported_func` has not been defined"} ==
               Wasmex.Instance.new(store, module, %{})
    end

    test "instantiates an Instance with imports" do
      imports = %{
        "env" => TestHelper.default_imported_functions_env_stringified()
      }

      %{store: store, module: module} = TestHelper.wasm_import_module()
      {:ok, _} = Wasmex.Instance.new(store, module, imports)
    end

    test "can not instantiate an Instance with imports having too few params" do
      imports = %{
        "env" =>
          TestHelper.default_imported_functions_env_stringified()
          |> Map.merge(%{
            "imported_sum3" => {:fn, [:i32, :i32], [:i32], fn _context, a, b -> a + b end}
          })
      }

      %{store: store, module: module} = TestHelper.wasm_import_module()
      {:error, reason} = Wasmex.Instance.new(store, module, imports)

      assert reason == "incompatible import type for `env::imported_sum3`"
    end

    test "can not instantiate an Instance with imports having too many params" do
      imports = %{
        "env" => %{
          "imported_sum3" =>
            {:fn, [:i32, :i32, :i32, :i32], [:i32], fn _context, a, b, c, d -> a + b + c + d end}
        }
      }

      %{store: store, module: module} = TestHelper.wasm_import_module()
      {:error, reason} = Wasmex.Instance.new(store, module, imports)

      assert reason == "unknown import: `env::imported_sumf` has not been defined"
    end

    test "can not instantiate an Instance with imports having wrong params types" do
      imports = %{
        "env" =>
          TestHelper.default_imported_functions_env_stringified()
          |> Map.merge(%{
            "imported_sum3" =>
              {:fn, [:i32, :i32, :i32], [:i64], fn _context, a, b, c -> a + b + c end}
          })
      }

      %{store: store, module: module} = TestHelper.wasm_import_module()
      {:error, reason} = Wasmex.Instance.new(store, module, imports)

      assert reason == "incompatible import type for `env::imported_sum3`"
    end
  end

  describe t(&Instance.function_export_exists/2) do
    test "returns whether a function export could be found in the wasm file" do
      %{store: store, instance: instance} = build_wasm_instance()
      assert Wasmex.Instance.function_export_exists(store, instance, "sum")
      refute Wasmex.Instance.function_export_exists(store, instance, "sum42")
    end
  end

  describe t(&Instance.call_exported_function/3) do
  end

  describe t(&Instance.memory/2) do
    test "returns a memory struct" do
      %{store: store, instance: instance} = build_wasm_instance()

      {:ok, %Wasmex.Memory{resource: _}} = Wasmex.Instance.memory(store, instance)
    end
  end

  describe "globals" do
    setup do
      wat = File.read!("#{Path.dirname(__ENV__.file)}/../example_wasm_files/globals.wat")
      {:ok, store} = Wasmex.Store.new()
      {:ok, module} = Wasmex.Module.compile(store, wat)
      {:ok, instance} = Wasmex.Instance.new(store, module, %{})
      %{instance: instance, store: store}
    end

    test t(&Wasmex.Instance.get_global_value/3), context do
      store = context[:store]
      instance = context[:instance]

      assert {:error, "exported global `unknown_global` not found"} =
               Wasmex.Instance.get_global_value(store, instance, "unknown_global")

      assert {:ok, 42} = Wasmex.Instance.get_global_value(store, instance, "meaning_of_life")
      assert {:ok, -32} = Wasmex.Instance.get_global_value(store, instance, "count_32")
      assert {:ok, -64} = Wasmex.Instance.get_global_value(store, instance, "count_64")

      assert {:error, "unable_to_return_extern_ref_type"} =
               Wasmex.Instance.get_global_value(store, instance, "externref")

      assert {:error, "unable_to_return_func_ref_type"} =
               Wasmex.Instance.get_global_value(store, instance, "funcref")
    end

    test t(&Wasmex.Instance.set_global_value/4), context do
      store = context[:store]
      instance = context[:instance]

      assert {:error, "exported global `unknown_global` not found"} =
               Wasmex.Instance.set_global_value(store, instance, "unknown_global", 0)

      assert {:error, "Could not set global: immutable global cannot be set"} =
               Wasmex.Instance.set_global_value(store, instance, "meaning_of_life", 0)

      assert {:error, "Cannot convert to a WebAssembly i32 value. Given `Atom`."} =
               Wasmex.Instance.set_global_value(store, instance, "count_32", :abc)

      assert :ok = Wasmex.Instance.set_global_value(store, instance, "count_32", 99)
      assert {:ok, 99} = Wasmex.Instance.get_global_value(store, instance, "count_32")

      assert :ok = Wasmex.Instance.set_global_value(store, instance, "count_64", 17)
      assert {:ok, 17} = Wasmex.Instance.get_global_value(store, instance, "count_64")

      assert :ok = Wasmex.Instance.set_global_value(store, instance, "bad_pi_32", 3.14)

      assert_in_delta 3.14,
                      elem(Wasmex.Instance.get_global_value(store, instance, "bad_pi_32"), 1),
                      0.01

      assert :ok = Wasmex.Instance.set_global_value(store, instance, "bad_pi_64", 3.14)

      assert_in_delta 3.14,
                      elem(Wasmex.Instance.get_global_value(store, instance, "bad_pi_64"), 1),
                      0.01
    end
  end
end
