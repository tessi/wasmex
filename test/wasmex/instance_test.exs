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
    test "runs functions which returns an integer" do
      {:ok, instance} = build_wasm_instance()
      assert 42 == Wasmex.Instance.call_exported_function(instance, "arity_0")
    end
  end

  describe "call_exported_function/3" do
    test "runs functions without params" do
      {:ok, instance} = build_wasm_instance()
      assert 42 == Wasmex.Instance.call_exported_function(instance, "arity_0", [])
    end

    test "calling the sum(i32, i32) function" do
      {:ok, instance} = build_wasm_instance()
      assert 42 == Wasmex.Instance.call_exported_function(instance, "sum", [50, -8])
    end

    test "calling the sum(i32, i32) function with wrong number of params" do
      {:ok, instance} = build_wasm_instance()
      assert_raise ErlangError, "Erlang error: \"number of params does not match. expected 2, got 1\"", fn ->
        Wasmex.Instance.call_exported_function(instance, "sum", [3])
      end

      assert_raise ErlangError, "Erlang error: \"number of params does not match. expected 2, got 3\"", fn ->
        Wasmex.Instance.call_exported_function(instance, "sum", [3, 4, 5])
      end
    end

    test "calling a function that does not exist" do
      {:ok, instance} = build_wasm_instance()
      assert_raise ErlangError, "Erlang error: \"exported function `sum42` not found\"", fn ->
        Wasmex.Instance.call_exported_function(instance, "sum42", [])
      end
    end

    test "using i32 as param and return value" do
      {:ok, instance} = build_wasm_instance()
      assert -3 == Wasmex.Instance.call_exported_function(instance, "i32_i32", [-3])

      # a value greater than i32::max_value()
      # see: https://doc.rust-lang.org/std/primitive.i32.html#method.max_value
      assert_raise ErlangError, "Erlang error: \"Cannot convert argument #1 to a WebAssembly i32 value.\"", fn ->
        Wasmex.Instance.call_exported_function(instance, "i32_i32", [3000000000])
      end
    end

    test "using i64 as param and return value" do
      {:ok, instance} = build_wasm_instance()
      assert -3 == Wasmex.Instance.call_exported_function(instance, "i64_i64", [-3])

      # a value greater than i32::max_value()
      # see: https://doc.rust-lang.org/std/primitive.i32.html#method.max_value
      assert 3000000000 == Wasmex.Instance.call_exported_function(instance, "i64_i64", [3000000000])
    end

    test "using f32 as param and return value" do
      {:ok, instance} = build_wasm_instance()
      assert_in_delta 3.14, Wasmex.Instance.call_exported_function(instance, "f32_f32", [3.14]), 0.001

      # a value greater than f32::max_value()
      assert_raise ArgumentError, fn ->
        Wasmex.Instance.call_exported_function(instance, "f32_f32", [3.4e42])
      end
    end

    test "using f64 as param and return value" do
      {:ok, instance} = build_wasm_instance()
      assert_in_delta 3.14, Wasmex.Instance.call_exported_function(instance, "f64_f64", [3.14]), 0.001

      # a value greater than f32::max_value()
      assert  3.4e42 == Wasmex.Instance.call_exported_function(instance, "f64_f64", [3.4e42])
    end

    test "using different param types as params" do
      {:ok, instance} = build_wasm_instance()
      assert_in_delta 20.4, Wasmex.Instance.call_exported_function(instance, "i32_i64_f32_f64_f64", [3, 4, 5.6, 7.8]), 0.001
    end

    test "calling a function with a boolean return value" do
      {:ok, instance} = build_wasm_instance()
      assert 1 == Wasmex.Instance.call_exported_function(instance, "bool_casted_to_i32", [])
    end

    test "calling a function with no return value" do
      {:ok, instance} = build_wasm_instance()
      assert nil == Wasmex.Instance.call_exported_function(instance, "void", [])
    end

    test "calling a function which returns a string pointer" do
      {:ok, instance} = build_wasm_instance()
      pointer = Wasmex.Instance.call_exported_function(instance, "string", [])
      {:ok, memory} = Wasmex.Instance.memory(instance, :uint8, 0)
      returned_string = Wasmex.Memory.read_binary(memory, pointer)
      assert returned_string == "Hello, World!"
    end

    test "calling a function which gets a string as param" do
      {:ok, instance} = build_wasm_instance()
      {:ok, memory} = Wasmex.Instance.memory(instance, :uint8, 0)
      string = "hello, world"
      index = 42

      Wasmex.Memory.write_binary(memory, index, string)
      assert 104 == Wasmex.Instance.call_exported_function(instance, "string_first_byte", [index, String.length(string)])
    end
  end

  describe "memory/3" do
    test "returns a memory struct" do
      {:ok, instance} = build_wasm_instance()
      {:ok, %Wasmex.Memory{size: :uint8, offset: 0, resource: _}} = Wasmex.Instance.memory(instance, :uint8, 0)
    end
  end
end
