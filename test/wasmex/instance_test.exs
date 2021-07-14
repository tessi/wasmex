defmodule Wasmex.InstanceTest do
  use ExUnit.Case, async: true
  doctest Wasmex.Instance

  defp build_wasm_instance do
    bytes = File.read!(TestHelper.wasm_test_file_path())
    Wasmex.Instance.from_bytes(bytes, %{})
  end

  describe "from_bytes/1" do
    test "instantiates an Instance from a valid wasm file" do
      bytes = File.read!(TestHelper.wasm_test_file_path())
      {:ok, _} = Wasmex.Instance.from_bytes(bytes, %{})
    end

    test "errors when not providing necessary imports" do
      bytes = File.read!("#{Path.dirname(__ENV__.file)}/../example_wasm_files/simple.wasm")

      assert {:error,
              "Cannot Instantiate: Link(Import(\"imports\", \"imported_func\", UnknownImport(Function(FunctionType { params: [I32], results: [] }))))"} ==
               Wasmex.Instance.from_bytes(bytes, %{})
    end

    test "instantiates an Instance with imports" do
      bytes = File.read!(TestHelper.wasm_import_test_file_path())

      imports = %{
        "env" => TestHelper.default_imported_functions_env_stringified()
      }

      {:ok, _} = Wasmex.Instance.from_bytes(bytes, imports)
    end

    test "can not instantiate an Instance with imports having too few params" do
      bytes = File.read!(TestHelper.wasm_import_test_file_path())

      imports = %{
        "env" =>
          TestHelper.default_imported_functions_env_stringified()
          |> Map.merge(%{
            "imported_sum3" => {:fn, [:i32, :i32], [:i32], fn _context, a, b -> a + b end}
          })
      }

      {:error, reason} = Wasmex.Instance.from_bytes(bytes, imports)

      assert reason =~
               "Cannot Instantiate: Link(Import(\"env\", \"imported_sum3\", IncompatibleType(Function(FunctionType { params: [I32, I32, I32], results: [I32] }), Function(FunctionType { params: [I32, I32], results: [I32] }))))"
    end

    test "can not instantiate an Instance with imports having too many params" do
      bytes = File.read!(TestHelper.wasm_import_test_file_path())

      imports = %{
        "env" => %{
          "imported_sum3" =>
            {:fn, [:i32, :i32, :i32, :i32], [:i32], fn _context, a, b, c, d -> a + b + c + d end}
        }
      }

      {:error, reason} = Wasmex.Instance.from_bytes(bytes, imports)

      assert reason =~
               "Cannot Instantiate: Link(Import(\"env\", \"imported_sum3\", IncompatibleType(Function(FunctionType { params: [I32, I32, I32], results: [I32] }), Function(FunctionType { params: [I32, I32, I32, I32], results: [I32] }))))"
    end

    test "can not instantiate an Instance with imports having wrong params types" do
      bytes = File.read!(TestHelper.wasm_import_test_file_path())

      imports = %{
        "env" =>
          TestHelper.default_imported_functions_env_stringified()
          |> Map.merge(%{
            "imported_sum3" =>
              {:fn, [:i32, :i32, :i32], [:i64], fn _context, a, b, c -> a + b + c end}
          })
      }

      {:error, reason} = Wasmex.Instance.from_bytes(bytes, imports)

      assert reason =~
               "Cannot Instantiate: Link(Import(\"env\", \"imported_sum3\", IncompatibleType(Function(FunctionType { params: [I32, I32, I32], results: [I32] }), Function(FunctionType { params: [I32, I32, I32], results: [I64] }))))"
    end
  end

  describe "function_export_exists/2" do
    test "returns whether a function export could be found in the wasm file" do
      {:ok, instance} = build_wasm_instance()
      assert Wasmex.Instance.function_export_exists(instance, "sum")
      # 🎸
      refute Wasmex.Instance.function_export_exists(instance, "sum42")
    end
  end

  describe "call_exported_function/3" do
    test "calling a function sends an async message back to self" do
      {:ok, instance} = build_wasm_instance()
      assert :ok == Wasmex.Instance.call_exported_function(instance, "arity_0", [], :fake_from)

      receive do
        {:returned_function_call, {:ok, [42]}, :fake_from} -> nil
      after
        2000 ->
          raise "message_expected"
      end
    end

    test "calling a function with error sends an error message back to self" do
      {:ok, instance} = build_wasm_instance()
      assert :ok == Wasmex.Instance.call_exported_function(instance, "arity_0", [1], :fake_from)

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
      {:ok, instance} = build_wasm_instance()

      assert :ok ==
               Wasmex.Instance.call_exported_function(instance, "endless_loop", [], :fake_from)

      receive do
        _ -> raise "no receive expected"
      after
        100 ->
          nil
      end
    end

    test "calling an imported function which returns the wrong type" do
      bytes = File.read!(TestHelper.wasm_import_test_file_path())

      imports = %{
        "env" =>
          TestHelper.default_imported_functions_env_stringified()
          |> Map.merge(%{
            "imported_sum3" =>
              {:fn, [:i32, :i32, :i32], [:i32], fn _context, _a, _b, _c -> 2.3 end},
            "imported_sumf" => {:fn, [:f32, :f32], [:f32], fn _context, _a, _b -> 4 end}
          })
      }

      {:ok, instance} = Wasmex.Instance.from_bytes(bytes, imports)

      :ok =
        Wasmex.Instance.call_exported_function(
          instance,
          "using_imported_sum3",
          [1, 2, 3],
          :fake_from
        )

      receive do
        {:invoke_callback, "env", "imported_sum3", _context, [1, 2, 3], _token} -> nil
        _ -> raise "should not be able to return results with the wrong type"
      after
        100 -> nil
      end

      :ok =
        Wasmex.Instance.call_exported_function(instance, "imported_sumf", [1.1, 2.2], :fake_from)

      receive do
        {:invoke_callback, "env", "imported_sumf", _context, [1.1, 2.2], _token} -> nil
        _ -> raise "should not be able to return results with the wrong type"
      after
        100 -> nil
      end
    end
  end

  describe "memory/3" do
    test "returns a memory struct" do
      {:ok, instance} = build_wasm_instance()

      {:ok, %Wasmex.Memory{size: :uint8, offset: 0, resource: _}} =
        Wasmex.Instance.memory(instance, :uint8, 0)
    end
  end
end
