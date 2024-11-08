defmodule WasmexTest do
  use ExUnit.Case, async: true
  import TestHelper, only: [t: 1]

  doctest Wasmex

  defp create_instance(_context) do
    %{module: module, store: store} = TestHelper.wasm_module()
    instance = start_supervised!({Wasmex, %{store: store, module: module}})
    %{instance: instance, module: module, store: store}
  end

  describe "when instantiating without imports" do
    setup [:create_instance]

    test t(&Wasmex.function_exists/2), %{instance: instance} do
      assert Wasmex.function_exists(instance, :arity_0)
      assert Wasmex.function_exists(instance, "arity_0")

      assert !Wasmex.function_exists(instance, :unknown_function)
      assert !Wasmex.function_exists(instance, "unknown_function")
    end

    test t(&Wasmex.store/1), %{instance: instance} do
      assert {:ok, %Wasmex.StoreOrCaller{}} = Wasmex.store(instance)
    end

    test t(&Wasmex.module/1), %{instance: instance} do
      assert {:ok, %Wasmex.Module{}} = Wasmex.module(instance)
    end

    test t(&Wasmex.call_function/3) <> " calling an unknown function", %{instance: instance} do
      assert {:error, "exported function `unknown_function` not found"} =
               Wasmex.call_function(instance, :unknown_function, [1])
    end

    test t(&Wasmex.call_function/3) <> " arity0 with too many params", %{instance: instance} do
      assert {:error, "number of params does not match. expected 0, got 1"} =
               Wasmex.call_function(instance, :arity_0, [1])
    end

    test t(&Wasmex.call_function/3) <> " arity0 -> i32", %{instance: instance} do
      assert {:ok, [42]} = Wasmex.call_function(instance, :arity_0, [])
      assert {:ok, [42]} = Wasmex.call_function(instance, "arity_0", [])
    end

    test t(&Wasmex.call_function/3) <> " sum(i32, i32) -> i32 function", %{instance: instance} do
      assert {:ok, [42]} == Wasmex.call_function(instance, :sum, [50, -8])
    end

    test t(&Wasmex.call_function/3) <> " i32_i32(i32) -> i32 function", %{instance: instance} do
      assert {:ok, [-3]} == Wasmex.call_function(instance, :i32_i32, [-3])

      # giving a value greater than i32::max_value()
      # see: https://doc.rust-lang.org/std/primitive.i32.html#method.max_value
      assert {:error, "Cannot convert argument #1 to a WebAssembly i32 value."} ==
               Wasmex.call_function(instance, :i32_i32, [3_000_000_000])
    end

    test t(&Wasmex.call_function/3) <> " i64_i64(i64) -> i64 function", %{instance: instance} do
      assert {:ok, [-3]} == Wasmex.call_function(instance, :i64_i64, [-3])

      # giving a value greater than i32::max_value()
      # see: https://doc.rust-lang.org/std/primitive.i32.html#method.max_value
      assert {:ok, [3_000_000_000]} ==
               Wasmex.call_function(instance, "i64_i64", [3_000_000_000])
    end

    test t(&Wasmex.call_function/3) <> " v128_v128(v128) -> v128 function", %{instance: instance} do
      assert {:ok, [42]} == Wasmex.call_function(instance, :v128_v128, [42])

      max_128_bit_int = 340_282_366_920_938_463_463_374_607_431_768_211_455

      assert {:ok, [max_128_bit_int]} ==
               Wasmex.call_function(instance, "v128_v128", [max_128_bit_int])

      assert {:error, "Cannot convert argument #1 to a WebAssembly v128 value."} ==
               Wasmex.call_function(instance, :v128_v128, [max_128_bit_int + 1])

      assert {:error, "Cannot convert argument #1 to a WebAssembly v128 value."} ==
               Wasmex.call_function(instance, :v128_v128, [-1])
    end

    test t(&Wasmex.call_function/3) <> " f32_f32(f32) -> f32 function", %{instance: instance} do
      {:ok, [result]} = Wasmex.call_function(instance, :f32_f32, [3.14])

      assert_in_delta 3.14,
                      result,
                      0.001

      # a value greater than f32::max_value()
      assert {:error, "Cannot convert argument #1 to a WebAssembly f32 value."} ==
               Wasmex.call_function(instance, :f32_f32, [3.5e38])
    end

    test t(&Wasmex.call_function/3) <> " f64_f64(f64) -> f64 function", %{instance: instance} do
      {:ok, [result]} = Wasmex.call_function(instance, :f64_f64, [3.14])

      assert_in_delta 3.14,
                      result,
                      0.001

      # a value greater than f32::max_value()
      assert {:ok, [3.5e38]} == Wasmex.call_function(instance, :f64_f64, [3.5e38])
    end

    test t(&Wasmex.call_function/3) <> " i32_i64_f32_f64_f64(i32, i64, f32, f64) -> f64 function",
         %{
           instance: instance
         } do
      {:ok, [result]} = Wasmex.call_function(instance, :i32_i64_f32_f64_f64, [3, 4, 5.6, 7.8])

      assert_in_delta 20.4,
                      result,
                      0.001
    end

    test t(&Wasmex.call_function/3) <> " bool_casted_to_i32() -> i32 function", %{
      instance: instance
    } do
      assert {:ok, [1]} == Wasmex.call_function(instance, :bool_casted_to_i32, [])
    end

    test t(&Wasmex.call_function/3) <> " void() -> () function", %{instance: instance} do
      assert {:ok, []} == Wasmex.call_function(instance, :void, [])
    end

    test t(&Wasmex.call_function/3) <> " string() -> string function", %{
      store: store,
      instance: instance
    } do
      {:ok, [pointer]} = Wasmex.call_function(instance, :string, [])
      {:ok, memory} = Wasmex.memory(instance)
      assert Wasmex.Memory.read_string(store, memory, pointer, 13) == "Hello, World!"
    end

    test t(&Wasmex.call_function/3) <> " string_first_byte(string_pointer) -> u8 function", %{
      store: store,
      instance: instance
    } do
      {:ok, memory} = Wasmex.memory(instance)
      string = "hello, world"
      index = 42
      Wasmex.Memory.write_binary(store, memory, index, string)

      assert {:ok, [104]} ==
               Wasmex.call_function(instance, :string_first_byte, [
                 index,
                 String.length(string)
               ])
    end
  end

  test "read and manipulate memory in a callback" do
    %{store: store, module: module} = TestHelper.wasm_import_module()

    imports = %{
      env:
        TestHelper.default_imported_functions_env()
        |> Map.put(
          :imported_sum3,
          {:fn, [:i32, :i32, :i32], [:i32],
           fn context, a, b, c ->
             assert 42 == Wasmex.Memory.get_byte(context.caller, context.memory, 0)
             Wasmex.Memory.set_byte(context.caller, context.memory, 0, 23)
             a + b + c
           end}
        )
    }

    instance = start_supervised!({Wasmex, %{store: store, module: module, imports: imports}})

    {:ok, memory} = Wasmex.memory(instance)
    Wasmex.Memory.set_byte(store, memory, 0, 42)

    # asserts that the byte at memory[0] was set to 42 and then sets it to 23
    {:ok, _} = Wasmex.call_function(instance, :using_imported_sum3, [1, 2, 3])

    assert 23 == Wasmex.Memory.get_byte(store, memory, 0)
  end

  describe "when instantiating with imports" do
    def create_instance_with_atom_imports(_context) do
      imports = %{
        env: TestHelper.default_imported_functions_env()
      }

      %{store: store, module: module} = TestHelper.wasm_import_module()

      instance = start_supervised!({Wasmex, %{store: store, module: module, imports: imports}})

      %{store: store, module: module, imports: imports, instance: instance}
    end

    setup [:create_instance_with_atom_imports]

    test "call_function using_imported_void for void() -> () callback", %{instance: instance} do
      assert {:ok, []} == Wasmex.call_function(instance, :using_imported_void, [])
    end

    test "call_function using_imported_sum3", %{instance: instance} do
      assert {:ok, [44]} ==
               Wasmex.call_function(instance, :using_imported_sum3, [23, 19, 2])

      assert {:ok, [28]} ==
               Wasmex.call_function(instance, :using_imported_sum3, [100, -77, 5])
    end

    test "call_function using_imported_sumf", %{instance: instance} do
      {:ok, [result]} = Wasmex.call_function(instance, :using_imported_sumf, [2.3, 1.9])
      assert_in_delta 4.2, result, 0.001

      assert {:ok, [result]} = Wasmex.call_function(instance, :using_imported_sumf, [10.0, -7.7])

      assert_in_delta 2.3, result, 0.001
    end
  end

  describe "when instantiating with imports using string keys for the imports object" do
    def create_instance_with_string_imports(_context) do
      imports = %{
        "env" => TestHelper.default_imported_functions_env_stringified()
      }

      %{store: store, module: module} = TestHelper.wasm_import_module()

      instance = start_supervised!({Wasmex, %{store: store, module: module, imports: imports}})

      %{store: store, module: module, instance: instance}
    end

    setup [:create_instance_with_string_imports]

    test "call_function using_imported_sum3 with both, string and atom, identifiers", %{
      instance: instance
    } do
      assert {:ok, [6]} ==
               Wasmex.call_function(instance, "using_imported_sum3", [1, 2, 3])

      assert {:ok, [6]} == Wasmex.call_function(instance, :using_imported_sum3, [1, 2, 3])
    end
  end

  describe "when instantiating with imports that raise exceptions" do
    def create_instance_with_imports_raising_exceptions(_context) do
      imports = %{
        env: %{
          imported_sum3:
            {:fn, [:i32, :i32, :i32], [:i32], fn _context, _a, _b, _c -> raise("oops") end},
          imported_sumf: {:fn, [:f32, :f32], [:f32], fn _context, _a, _b -> raise("oops") end},
          imported_void: {:fn, [], [], fn _context -> raise("oops") end}
        }
      }

      %{store: store, module: module} = TestHelper.wasm_import_module()

      instance = start_supervised!({Wasmex, %{store: store, module: module, imports: imports}})

      %{store: store, module: module, instance: instance}
    end

    setup [:create_instance_with_imports_raising_exceptions]

    test "call_function returns an error tuple", %{
      instance: instance
    } do
      assert {:error, reason} = Wasmex.call_function(instance, "using_imported_sum3", [1, 2, 3])

      assert reason =~
               ~r/Error during function excecution: `error while executing at wasm backtrace:\n\s*0:\s*0x.* - .*\!using_imported_sum3`\./
    end
  end

  describe "error handling" do
    test "handles errors occurring during Wasm execution with default engine config" do
      config =
        %Wasmex.EngineConfig{}
        |> Wasmex.EngineConfig.wasm_backtrace_details(false)

      {:ok, engine} = Wasmex.Engine.new(config)
      {:ok, store} = Wasmex.Store.new(nil, engine)
      bytes = File.read!(TestHelper.wasm_test_file_path())
      {:ok, module} = Wasmex.Module.compile(store, bytes)
      {:ok, pid} = Wasmex.start_link(%{store: store, module: module})

      assert {:error, err_msg} = Wasmex.call_function(pid, :divide, [1, 0])

      assert String.starts_with?(
               err_msg,
               "Error during function excecution: `error while executing at wasm backtrace:"
             )
    end

    test "handles errors occuring during Wasm execution with wasm_backtrace_details enabled" do
      config =
        %Wasmex.EngineConfig{}
        |> Wasmex.EngineConfig.wasm_backtrace_details(true)

      {:ok, engine} = Wasmex.Engine.new(config)
      {:ok, store} = Wasmex.Store.new(nil, engine)
      bytes = File.read!(TestHelper.wasm_test_file_path())
      {:ok, module} = Wasmex.Module.compile(store, bytes)
      {:ok, pid} = Wasmex.start_link(%{store: store, module: module})

      assert {:error, reason} = Wasmex.call_function(pid, :divide, [1, 0])

      # contains source file and line number
      assert reason =~ "wasmex/test/wasm_test/src/lib.rs:75:5"
    end
  end

  describe "fuel consumption" do
    test t(&Wasmex.call_function/3) <> " with fuel_consumption" do
      {:ok, engine} = Wasmex.Engine.new(%Wasmex.EngineConfig{consume_fuel: true})
      {:ok, store} = Wasmex.Store.new(nil, engine)
      bytes = File.read!(TestHelper.wasm_test_file_path())
      pid = start_supervised!({Wasmex, %{store: store, bytes: bytes}})
      Wasmex.StoreOrCaller.set_fuel(store, 2)

      assert Wasmex.call_function(pid, :void, []) == {:ok, []}
      assert Wasmex.StoreOrCaller.get_fuel(store) == {:ok, 1}

      assert {:error, err_msg} = Wasmex.call_function(pid, :void, [])

      assert err_msg =~
               ~r/Error during function excecution: `error while executing at wasm backtrace:\n.+0:.+0x.+ - .*\!void`\./
    end
  end

  describe "multi-value function calls" do
    test "calls a function with multi-value params and return" do
      wat = """
      (module
        (func $call (export "call") (param i32 i64) (result i64 i32)
          (local.get 1) (local.get 0)
        )
      )
      """

      {:ok, store} = Wasmex.Store.new()
      {:ok, module} = Wasmex.Module.compile(store, wat)
      pid = start_supervised!({Wasmex, %{store: store, module: module}})
      assert Wasmex.call_function(pid, :call, [1, 2]) == {:ok, [2, 1]}
    end

    test "calling an imported function that has multi-value params and return values" do
      wat = """
      (module
        (func $reorder (import "env" "reorder") (param i32 i64) (result i64 i32))

        (func $call (export "call") (param i32 i64) (result i64 i32)
          (call $reorder (local.get 0) (local.get 1))
        )
      )
      """

      imports = %{
        env: %{reorder: {:fn, [:i32, :i64], [:i64, :i32], fn _context, a, b -> [b, a] end}}
      }

      {:ok, store} = Wasmex.Store.new()
      {:ok, module} = Wasmex.Module.compile(store, wat)
      pid = start_supervised!({Wasmex, %{store: store, module: module, imports: imports}})
      assert Wasmex.call_function(pid, :call, [1, 2]) == {:ok, [2, 1]}
    end

    test "calling multi-value functions with more than two values" do
      wat = """
      (module
        (func $reverse
          (export "reverse")
          (param i64 i64 i64 i64 i64 i64 i64 i64 i64 i64)
          (result i64 i64 i64 i64 i64 i64 i64 i64 i64 i64)

          local.get 9
          local.get 8
          local.get 7
          local.get 6
          local.get 5
          local.get 4
          local.get 3
          local.get 2
          local.get 1
          local.get 0
        )
      )
      """

      {:ok, store} = Wasmex.Store.new()
      {:ok, module} = Wasmex.Module.compile(store, wat)
      pid = start_supervised!({Wasmex, %{store: store, module: module}})

      assert Wasmex.call_function(pid, :reverse, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]) ==
               {:ok, [9, 8, 7, 6, 5, 4, 3, 2, 1, 0]}
    end

    test "using multi-value params to encode strings" do
      wat = """
      (module
        (memory $memory 1)
        ;; Store the Hello World (null terminated) string at byte offset 42
        (data (i32.const 42) "Hello World!")

        (export "memory" (memory $memory))
        (func $call (export "call") (result i32 i32)
          ;; return the byte offset (address in memory) of the string and its length as two separate values
          (i32.const 42) (i32.const 12)
        )
      )
      """

      {:ok, store} = Wasmex.Store.new()
      {:ok, module} = Wasmex.Module.compile(store, wat)
      pid = start_supervised!({Wasmex, %{store: store, module: module}})
      assert {:ok, [string_ptr, length]} = Wasmex.call_function(pid, :call, [])

      {:ok, memory} = Wasmex.memory(pid)
      assert Wasmex.Memory.read_string(store, memory, string_ptr, length) == "Hello World!"
    end
  end

  describe "call exported function in imported function callback" do
    test "using instance in callback" do
      wat = """
      (module
        (func $add_import (import "env" "add_import") (param i32 i32) (result i32))

        (func $call_import (export "call_import") (param i32 i32) (result i32)
          (call $add_import (local.get 0) (local.get 1))
        )

        (func $call_add (export "call_add") (param i32 i32) (result i32)
          local.get 0
          local.get 1
          i32.add
        )
      )
      """

      imports = %{
        env: %{
          add_import:
            {:fn, [:i32, :i32], [:i32],
             fn %{instance: instance, caller: caller}, a, b ->
               Wasmex.Instance.call_exported_function(caller, instance, "call_add", [a, b], :from)

               receive do
                 {
                   :returned_function_call,
                   {:ok, [result]},
                   :from
                 } ->
                   :ok
                   result
               after
                 1000 ->
                   raise "timeout on exported function call"
               end
             end}
        }
      }

      {:ok, store} = Wasmex.Store.new()
      {:ok, module} = Wasmex.Module.compile(store, wat)
      pid = start_supervised!({Wasmex, %{store: store, module: module, imports: imports}})
      assert Wasmex.call_function(pid, :call_import, [1, 2]) == {:ok, [3]}
    end
  end
end
