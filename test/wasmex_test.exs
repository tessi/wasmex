defmodule WasmexTest do
  use ExUnit.Case, async: true
  import TestHelper, only: [t: 1]

  doctest Wasmex

  defp start_wasmex_gen_server(_context) do
    %{module: module, store: store} = TestHelper.wasm_module()
    pid = start_supervised!({Wasmex, %{store: store, module: module}})
    %{pid: pid, module: module, store: store}
  end

  describe "when instantiating without imports" do
    setup [:start_wasmex_gen_server]

    test t(&Wasmex.function_exists/2), %{pid: pid} do
      assert Wasmex.function_exists(pid, :arity_0)
      assert Wasmex.function_exists(pid, "arity_0")

      assert !Wasmex.function_exists(pid, :unknown_function)
      assert !Wasmex.function_exists(pid, "unknown_function")
    end

    test t(&Wasmex.store/1), %{pid: pid} do
      assert {:ok, %Wasmex.StoreOrCaller{}} = Wasmex.store(pid)
    end

    test t(&Wasmex.module/1), %{pid: pid} do
      assert {:ok, %Wasmex.Module{}} = Wasmex.module(pid)
    end

    test t(&Wasmex.call_function/3) <> " calling an unknown function", %{pid: pid} do
      assert {:error, "exported function `unknown_function` not found"} =
               Wasmex.call_function(pid, :unknown_function, [1])
    end

    test t(&Wasmex.call_function/3) <> " arity0 with too many params", %{pid: pid} do
      assert {:error, "number of params does not match. expected 0, got 1"} =
               Wasmex.call_function(pid, :arity_0, [1])
    end

    test t(&Wasmex.call_function/3) <> " arity0 -> i32", %{pid: pid} do
      assert {:ok, [42]} = Wasmex.call_function(pid, :arity_0, [])
      assert {:ok, [42]} = Wasmex.call_function(pid, "arity_0", [])
    end

    test t(&Wasmex.call_function/3) <> " sum(i32, i32) -> i32 function", %{pid: pid} do
      assert {:ok, [42]} == Wasmex.call_function(pid, :sum, [50, -8])
    end

    test t(&Wasmex.call_function/3) <> " i32_i32(i32) -> i32 function", %{pid: pid} do
      assert {:ok, [-3]} == Wasmex.call_function(pid, :i32_i32, [-3])

      # giving a value greater than i32::max_value()
      # see: https://doc.rust-lang.org/std/primitive.i32.html#method.max_value
      assert {:error, "Cannot convert argument #1 to a WebAssembly i32 value."} ==
               Wasmex.call_function(pid, :i32_i32, [3_000_000_000])
    end

    test t(&Wasmex.call_function/3) <> " i64_i64(i64) -> i64 function", %{pid: pid} do
      assert {:ok, [-3]} == Wasmex.call_function(pid, :i64_i64, [-3])

      # giving a value greater than i32::max_value()
      # see: https://doc.rust-lang.org/std/primitive.i32.html#method.max_value
      assert {:ok, [3_000_000_000]} ==
               Wasmex.call_function(pid, "i64_i64", [3_000_000_000])
    end

    test t(&Wasmex.call_function/3) <> " v128_v128(v128) -> v128 function", %{pid: pid} do
      assert {:ok, [42]} == Wasmex.call_function(pid, :v128_v128, [42])

      max_128_bit_int = 340_282_366_920_938_463_463_374_607_431_768_211_455

      assert {:ok, [max_128_bit_int]} ==
               Wasmex.call_function(pid, "v128_v128", [max_128_bit_int])

      assert {:error, "Cannot convert argument #1 to a WebAssembly v128 value."} ==
               Wasmex.call_function(pid, :v128_v128, [max_128_bit_int + 1])

      assert {:error, "Cannot convert argument #1 to a WebAssembly v128 value."} ==
               Wasmex.call_function(pid, :v128_v128, [-1])
    end

    test t(&Wasmex.call_function/3) <> " f32_f32(f32) -> f32 function", %{pid: pid} do
      {:ok, [result]} = Wasmex.call_function(pid, :f32_f32, [3.14])

      assert_in_delta 3.14,
                      result,
                      0.001

      # a value greater than f32::max_value()
      assert {:error, "Cannot convert argument #1 to a WebAssembly f32 value."} ==
               Wasmex.call_function(pid, :f32_f32, [3.5e38])
    end

    test t(&Wasmex.call_function/3) <> " f64_f64(f64) -> f64 function", %{pid: pid} do
      {:ok, [result]} = Wasmex.call_function(pid, :f64_f64, [3.14])

      assert_in_delta 3.14,
                      result,
                      0.001

      # a value greater than f32::max_value()
      assert {:ok, [3.5e38]} == Wasmex.call_function(pid, :f64_f64, [3.5e38])
    end

    test t(&Wasmex.call_function/3) <> " i32_i64_f32_f64_f64(i32, i64, f32, f64) -> f64 function",
         %{pid: pid} do
      {:ok, [result]} = Wasmex.call_function(pid, :i32_i64_f32_f64_f64, [3, 4, 5.6, 7.8])

      assert_in_delta 20.4,
                      result,
                      0.001
    end

    test t(&Wasmex.call_function/3) <> " bool_casted_to_i32() -> i32 function", %{
      pid: pid
    } do
      assert {:ok, [1]} == Wasmex.call_function(pid, :bool_casted_to_i32, [])
    end

    test t(&Wasmex.call_function/3) <> " void() -> () function", %{pid: pid} do
      assert {:ok, []} == Wasmex.call_function(pid, :void, [])
    end

    test t(&Wasmex.call_function/3) <> " string() -> string function", %{
      store: store,
      pid: pid
    } do
      {:ok, [pointer]} = Wasmex.call_function(pid, :string, [])
      {:ok, memory} = Wasmex.memory(pid)
      assert Wasmex.Memory.read_string(store, memory, pointer, 13) == "Hello, World!"
    end

    test t(&Wasmex.call_function/3) <> " string_first_byte(string_pointer) -> u8 function", %{
      store: store,
      pid: pid
    } do
      {:ok, memory} = Wasmex.memory(pid)
      string = "hello, world"
      index = 42
      Wasmex.Memory.write_binary(store, memory, index, string)

      assert {:ok, [104]} ==
               Wasmex.call_function(pid, :string_first_byte, [
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

    pid = start_supervised!({Wasmex, %{store: store, module: module, imports: imports}})

    {:ok, memory} = Wasmex.memory(pid)
    Wasmex.Memory.set_byte(store, memory, 0, 42)

    # asserts that the byte at memory[0] was set to 42 and then sets it to 23
    {:ok, _} = Wasmex.call_function(pid, :using_imported_sum3, [1, 2, 3])

    assert 23 == Wasmex.Memory.get_byte(store, memory, 0)
  end

  describe "when instantiating with imports" do
    def setup_atom_imports(_context) do
      imports = %{
        env: TestHelper.default_imported_functions_env()
      }

      %{store: store, module: module} = TestHelper.wasm_import_module()
      pid = start_supervised!({Wasmex, %{store: store, module: module, imports: imports}})

      %{store: store, module: module, imports: imports, pid: pid}
    end

    setup [:setup_atom_imports]

    test "call_function using_imported_void for void() -> () callback", %{pid: pid} do
      assert {:ok, []} == Wasmex.call_function(pid, :using_imported_void, [])
    end

    test "call_function using_imported_sum3", %{pid: pid} do
      assert {:ok, [44]} ==
               Wasmex.call_function(pid, :using_imported_sum3, [23, 19, 2])

      assert {:ok, [28]} ==
               Wasmex.call_function(pid, :using_imported_sum3, [100, -77, 5])
    end

    test "call_function using_imported_sumf", %{pid: pid} do
      {:ok, [result]} = Wasmex.call_function(pid, :using_imported_sumf, [2.3, 1.9])
      assert_in_delta 4.2, result, 0.001

      assert {:ok, [result]} = Wasmex.call_function(pid, :using_imported_sumf, [10.0, -7.7])

      assert_in_delta 2.3, result, 0.001
    end
  end

  describe "when instantiating with imports using string keys for the imports object" do
    def setup_string_imports(_context) do
      imports = %{
        "env" => TestHelper.default_imported_functions_env_stringified()
      }

      %{store: store, module: module} = TestHelper.wasm_import_module()
      pid = start_supervised!({Wasmex, %{store: store, module: module, imports: imports}})

      %{store: store, module: module, pid: pid}
    end

    setup [:setup_string_imports]

    test "call_function using_imported_sum3 with both, string and atom, identifiers", %{
      pid: pid
    } do
      assert {:ok, [6]} ==
               Wasmex.call_function(pid, "using_imported_sum3", [1, 2, 3])

      assert {:ok, [6]} == Wasmex.call_function(pid, :using_imported_sum3, [1, 2, 3])
    end
  end

  describe "when instantiating with imports that raise exceptions" do
    def setup_imports_with_raising_exceptions(_context) do
      imports = %{
        env: %{
          imported_sum3:
            {:fn, [:i32, :i32, :i32], [:i32], fn _context, _a, _b, _c -> raise("oops") end},
          imported_sumf: {:fn, [:f32, :f32], [:f32], fn _context, _a, _b -> raise("oops") end},
          imported_void: {:fn, [], [], fn _context -> raise("oops") end}
        }
      }

      %{store: store, module: module} = TestHelper.wasm_import_module()
      pid = start_supervised!({Wasmex, %{store: store, module: module, imports: imports}})

      %{store: store, module: module, pid: pid}
    end

    setup [:setup_imports_with_raising_exceptions]

    test "call_function returns an error tuple", %{
      pid: pid
    } do
      assert {:error, reason} = Wasmex.call_function(pid, "using_imported_sum3", [1, 2, 3])

      assert reason =~
               ~r/Error during function excecution: error while executing at wasm backtrace:\n\s*0:\s*0x.* - .*\!using_imported_sum3/
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
               "Error during function excecution (wasm trap: wasm `unreachable` instruction executed): error while executing at wasm backtrace:"
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
      assert reason =~ "wasm_test/src/lib.rs:75:5"
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
               ~r/Error during function excecution \(wasm trap: all fuel consumed by WebAssembly\): error while executing at wasm backtrace:\n.+0:.+0x.+ - .*\!void/
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
               ref = make_ref()
               from = {self(), ref}
               Wasmex.Instance.call_exported_function(caller, instance, "call_add", [a, b], from)

               receive do
                 {^ref, {:ok, [result]}} ->
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

  describe "unsafe_deserialize && serialize modules" do
    test "serializing a formerly deserialized module and runnung it" do
      engine = Wasmex.Engine.default()
      bytes = File.read!(TestHelper.wasm_test_file_path())
      {:ok, serialized_module} = Wasmex.Engine.precompile_module(engine, bytes)

      {:ok, store} = Wasmex.Store.new(nil, engine)
      {:ok, module} = Wasmex.Module.unsafe_deserialize(serialized_module, engine)
      {:ok, instance} = Wasmex.Instance.new(store, module, %{}, [])
      {:ok, pid} = Wasmex.start_link(%{store: store, module: module, instance: instance})

      assert {:ok, [42]} == Wasmex.call_function(pid, :sum, [50, -8])
    end
  end

  describe "concurrent execution" do
    test "parallel function calls" do
      wat = """
      (module
        (func $identity (param i32) (result i32)
          local.get 0)
        (export "identity" (func $identity))
      )
      """

      {:ok, store} = Wasmex.Store.new()
      {:ok, module} = Wasmex.Module.compile(store, wat)
      {:ok, pid} = Wasmex.start_link(%{store: store, module: module})

      # Launch multiple concurrent calls
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            {:ok, [^i]} = Wasmex.call_function(pid, :identity, [i])
            i
          end)
        end

      results = Task.await_many(tasks)
      assert results == Enum.to_list(1..10)
    end

    test "high concurrency - 1000 concurrent WebAssembly function calls" do
      # This test demonstrates Tokio's efficiency with green threads vs OS threads
      wat = """
      (module
        (func $add (export "add") (param i32 i32) (result i32)
          local.get 0
          local.get 1
          i32.add
        )
      )
      """

      {:ok, pid} = Wasmex.start_link(%{bytes: wat})

      # Launch 1000 concurrent operations - would be problematic with OS threads
      tasks =
        for i <- 1..1000 do
          Task.async(fn ->
            {:ok, [result]} = Wasmex.call_function(pid, :add, [i, i])
            result
          end)
        end

      results = Task.await_many(tasks, 10_000)
      expected = for i <- 1..1000, do: i * 2
      assert results == expected
    end

    test "BEAM scheduler remains responsive during heavy WebAssembly execution" do
      # Create a WebAssembly module with a CPU-intensive function
      wat = """
      (module
        (func $fibonacci (export "fibonacci") (param i32) (result i32)
          (local i32 i32 i32 i32)
          local.get 0
          i32.const 2
          i32.lt_s
          if (result i32)
            local.get 0
          else
            i32.const 0
            local.set 1
            i32.const 1
            local.set 2
            i32.const 2
            local.set 3
            block
              loop
                local.get 1
                local.get 2
                i32.add
                local.set 4
                local.get 2
                local.set 1
                local.get 4
                local.set 2
                local.get 3
                i32.const 1
                i32.add
                local.tee 3
                local.get 0
                i32.gt_s
                br_if 1
                br 0
              end
            end
            local.get 2
          end
        )
      )
      """

      {:ok, pid} = Wasmex.start_link(%{bytes: wat})

      # Start multiple heavy computations
      wasm_tasks =
        for n <- [30, 31, 32, 33, 34] do
          Task.async(fn ->
            {:ok, [_result]} = Wasmex.call_function(pid, :fibonacci, [n])
            :completed
          end)
        end

      # Meanwhile, ensure BEAM scheduler stays responsive
      # by doing pure Elixir work in parallel
      beam_task =
        Task.async(fn ->
          start_time = System.monotonic_time(:millisecond)

          # Do some work that requires scheduler responsiveness
          for _ <- 1..100 do
            # Should complete in ~100ms if scheduler is responsive
            Process.sleep(1)
          end

          elapsed = System.monotonic_time(:millisecond) - start_time
          elapsed
        end)

      # The BEAM task should complete quickly even while WASM is running
      beam_elapsed = Task.await(beam_task, 5_000)

      # Should take roughly 100-200ms if scheduler isn't blocked
      # Even in CI, with DirtyCpu properly set, this should be under 1 second
      assert beam_elapsed < 1_000, "BEAM scheduler was blocked (took #{beam_elapsed}ms)"

      # Wait for WASM tasks to complete
      Task.await_many(wasm_tasks, 10_000)
    end

    test "error handling in highly concurrent scenario" do
      # Test that errors in some tasks don't affect others
      wat = """
      (module
        (func $may_fail (export "may_fail") (param i32) (result i32)
          local.get 0
          i32.const 50
          i32.gt_s
          if
            unreachable  ;; This will trap for values > 50
          end
          local.get 0
          i32.const 2
          i32.mul
        )
      )
      """

      {:ok, pid} = Wasmex.start_link(%{bytes: wat})

      # Launch many concurrent operations, some will fail
      tasks =
        for i <- 1..100 do
          Task.async(fn ->
            case Wasmex.call_function(pid, :may_fail, [i]) do
              {:ok, [result]} -> {:success, result}
              {:error, _reason} -> {:failed, i}
            end
          end)
        end

      results = Task.await_many(tasks, 10_000)

      {successes, failures} =
        Enum.split_with(results, fn
          {:success, _} -> true
          {:failed, _} -> false
        end)

      # First 50 should succeed, rest should fail (traps)
      assert length(successes) == 50
      assert length(failures) == 50
    end
  end

  describe "error handling with direct replies" do
    test "function that traps raises exception" do
      wat = """
      (module
        (func $trap (export "trap")
          unreachable
        )
      )
      """

      {:ok, pid} = Wasmex.start_link(%{bytes: wat})

      assert {:error, err_msg} = Wasmex.call_function(pid, :trap, [])
      assert err_msg =~ ~r/unreachable/
    end

    test "function with wrong parameters returns error" do
      wat = """
      (module
        (func $add (export "add") (param i32 i32) (result i32)
          local.get 0
          local.get 1
          i32.add
        )
      )
      """

      {:ok, pid} = Wasmex.start_link(%{bytes: wat})

      # Wrong number of params
      assert {:error, reason} = Wasmex.call_function(pid, :add, [1])
      assert reason =~ "params"

      # Wrong param type
      assert {:error, reason} = Wasmex.call_function(pid, :add, ["not", "numbers"])
      assert reason =~ "Cannot convert"
    end

    test "non-existent function returns error" do
      wat = """
      (module
        (func $foo (export "foo"))
      )
      """

      {:ok, pid} = Wasmex.start_link(%{bytes: wat})

      assert {:error, reason} = Wasmex.call_function(pid, :bar, [])
      assert reason =~ "not found"
    end

    test "divide by zero returns an error" do
      wat = """
      (module
        (func $divide (export "divide") (param i32 i32) (result i32)
          local.get 0
          local.get 1
          i32.div_s
        )
      )
      """

      {:ok, pid} = Wasmex.start_link(%{bytes: wat})

      assert {:error, err_msg} = Wasmex.call_function(pid, :divide, [10, 0])
      assert err_msg =~ ~r/div(ide|ision) by zero/
    end
  end
end
