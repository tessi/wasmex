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
              "Cannot Instantiate: LinkError([ImportNotFound { namespace: \"imports\", name: \"imported_func\" }])"} ==
               Wasmex.Instance.from_bytes(bytes, %{})
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
        1000 ->
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
        1000 ->
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
  end

  describe "memory/3" do
    test "returns a memory struct" do
      {:ok, instance} = build_wasm_instance()

      {:ok, %Wasmex.Memory{size: :uint8, offset: 0, resource: _}} =
        Wasmex.Instance.memory(instance, :uint8, 0)
    end
  end
end
