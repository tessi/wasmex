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
      # 🎸
      refute Wasmex.Instance.function_export_exists(store, instance, "sum42")
    end
  end

  describe t(&Instance.call_exported_function/3) do
    test "calling a function sends an async message back to self" do
      %{store: store, instance: instance} = build_wasm_instance()

      assert :ok ==
               Wasmex.Instance.call_exported_function(
                 store,
                 instance,
                 "arity_0",
                 [],
                 :fake_from
               )

      receive do
        {:returned_function_call, {:ok, [42]}, :fake_from} -> nil
      after
        2000 ->
          raise "message_expected"
      end
    end

    test "calling a function with error sends an error message back to self" do
      %{store: store, instance: instance} = build_wasm_instance()

      assert :ok ==
               Wasmex.Instance.call_exported_function(
                 store,
                 instance,
                 "arity_0",
                 [1],
                 :fake_from
               )

      receive do
        {:returned_function_call, {:error, "number of params does not match. expected 0, got 1"},
         :fake_from} ->
          nil
      after
        2000 ->
          raise "message_expected"
      end
    end

    test "calling a function that never returns" do
      %{store: store, instance: instance} = build_wasm_instance()

      assert :ok ==
               Wasmex.Instance.call_exported_function(
                 store,
                 instance,
                 "endless_loop",
                 [],
                 :fake_from
               )

      receive do
        _ -> raise "no receive expected"
      after
        100 ->
          nil
      end
    end

    test "calling an imported function which returns the wrong type" do
      imports = %{
        "env" =>
          TestHelper.default_imported_functions_env_stringified()
          |> Map.merge(%{
            "imported_sum3" =>
              {:fn, [:i32, :i32, :i32], [:i32], fn _context, _a, _b, _c -> 2.3 end},
            "imported_sumf" => {:fn, [:f32, :f32], [:f32], fn _context, _a, _b -> 4 end}
          })
      }

      %{store: store, module: module} = TestHelper.wasm_import_module()
      {:ok, instance} = Wasmex.Instance.new(store, module, imports)

      :ok =
        Wasmex.Instance.call_exported_function(
          store,
          instance,
          "using_imported_sum3",
          [1, 2, 3],
          :fake_from
        )

      receive do
        {:invoke_callback, "env", "imported_sum3", %{memory: _reference}, [1, 2, 3], _token} ->
          nil

        _ ->
          raise "should not be able to return results with the wrong type"
      after
        2000 -> raise("must receive response")
      end
    end
  end

  describe t(&Instance.memory/2) do
    test "returns a memory struct" do
      %{store: store, instance: instance} = build_wasm_instance()

      {:ok, %Wasmex.Memory{resource: _}} = Wasmex.Instance.memory(store, instance)
    end
  end

  describe "globals" do
    setup do
      source = File.read!("#{Path.dirname(__ENV__.file)}/../example_wasm_files/globals.wat")
      {:ok, store} = Wasmex.Store.new()
      {:ok, module} = Wasmex.Module.compile(store, source)
      {:ok, instance} = Wasmex.Instance.new(store, module, %{})
      %{instance: instance, store: store}
    end

    test "getting a global value", context do
      store = context[:store]
      instance = context[:instance]

      assert {:error, "exported global `unknown_global` not found"} =
               Wasmex.Instance.read_global(store, instance, "unknown_global")

      assert 42 = Wasmex.Instance.read_global(store, instance, "meaning_of_life")
      assert 0 = Wasmex.Instance.read_global(store, instance, "count")
    end

    test "setting a global value", context do
      store = context[:store]
      instance = context[:instance]

      assert {:error, "exported global `unknown_global` not found"} =
               Wasmex.Instance.write_global(store, instance, "unknown_global", 0)

      assert {:error, "Could not set global: immutable global cannot be set"} =
               Wasmex.Instance.write_global(store, instance, "meaning_of_life", 0)

      assert :ok = Wasmex.Instance.write_global(store, instance, "count", 99)
      assert 99 = Wasmex.Instance.read_global(store, instance, "count")
    end
  end
end
