defmodule WasmexTest do
  use ExUnit.Case, async: true
  doctest Wasmex

  @bytes File.read!(TestHelper.wasm_test_file_path())
  @import_test_bytes File.read!(TestHelper.wasm_import_test_file_path())
  @wasi_test_bytes File.read!(TestHelper.wasi_test_file_path())

  defp create_instance(_context) do
    instance = start_supervised!({Wasmex, @bytes})
    %{instance: instance}
  end

  describe "when instantiating without imports" do
    setup [:create_instance]

    test "function_exists", %{instance: instance} do
      assert Wasmex.function_exists(instance, :arity_0)
      assert Wasmex.function_exists(instance, "arity_0")

      assert !Wasmex.function_exists(instance, :unknown_function)
      assert !Wasmex.function_exists(instance, "unknown_function")
    end

    test "call_function: calling an unknown function", %{instance: instance} do
      assert {:error, "exported function `unknown_function` not found"} =
               Wasmex.call_function(instance, :unknown_function, [1])
    end

    test "call_function: arity0 with too many params", %{instance: instance} do
      assert {:error, "number of params does not match. expected 0, got 1"} =
               Wasmex.call_function(instance, :arity_0, [1])
    end

    test "call_function: arity0 -> i32", %{instance: instance} do
      assert {:ok, [42]} = Wasmex.call_function(instance, :arity_0, [])
      assert {:ok, [42]} = Wasmex.call_function(instance, "arity_0", [])
    end

    test "call_function: sum(i32, i32) -> i32 function", %{instance: instance} do
      assert {:ok, [42]} == Wasmex.call_function(instance, :sum, [50, -8])
    end

    test "call_function: i32_i32(i32) -> i32 function", %{instance: instance} do
      assert {:ok, [-3]} == Wasmex.call_function(instance, :i32_i32, [-3])

      # giving a value greater than i32::max_value()
      # see: https://doc.rust-lang.org/std/primitive.i32.html#method.max_value
      assert {:error, "Cannot convert argument #1 to a WebAssembly i32 value."} ==
               Wasmex.call_function(instance, :i32_i32, [3_000_000_000])
    end

    test "call_function: i64_i64(i64) -> i64 function", %{instance: instance} do
      assert {:ok, [-3]} == Wasmex.call_function(instance, :i64_i64, [-3])

      # giving a value greater than i32::max_value()
      # see: https://doc.rust-lang.org/std/primitive.i32.html#method.max_value
      assert {:ok, [3_000_000_000]} == Wasmex.call_function(instance, "i64_i64", [3_000_000_000])
    end

    test "call_function: f32_f32(f32) -> f32 function", %{instance: instance} do
      {:ok, [result]} = Wasmex.call_function(instance, :f32_f32, [3.14])

      assert_in_delta 3.14,
                      result,
                      0.001

      # a value greater than f32::max_value()
      assert {:error, "Cannot convert argument #1 to a WebAssembly f32 value."} ==
               Wasmex.call_function(instance, :f32_f32, [3.5e38])
    end

    test "call_function: f64_f64(f64) -> f64 function", %{instance: instance} do
      {:ok, [result]} = Wasmex.call_function(instance, :f64_f64, [3.14])

      assert_in_delta 3.14,
                      result,
                      0.001

      # a value greater than f32::max_value()
      assert {:ok, [3.5e38]} == Wasmex.call_function(instance, :f64_f64, [3.5e38])
    end

    test "call_function: i32_i64_f32_f64_f64(i32, i64, f32, f64) -> f64 function", %{
      instance: instance
    } do
      {:ok, [result]} = Wasmex.call_function(instance, :i32_i64_f32_f64_f64, [3, 4, 5.6, 7.8])

      assert_in_delta 20.4,
                      result,
                      0.001
    end

    test "call_function: bool_casted_to_i32() -> i32 function", %{instance: instance} do
      assert {:ok, [1]} == Wasmex.call_function(instance, :bool_casted_to_i32, [])
    end

    test "call_function: void() -> () function", %{instance: instance} do
      assert {:ok, []} == Wasmex.call_function(instance, :void, [])
    end

    test "call_function: string() -> string function", %{instance: instance} do
      {:ok, [pointer]} = Wasmex.call_function(instance, :string, [])
      {:ok, memory} = Wasmex.memory(instance, :uint8, 0)
      assert Wasmex.Memory.read_string(memory, pointer, 13) == "Hello, World!"
    end

    test "call_function: string_first_byte(string_pointer) -> u8 function", %{instance: instance} do
      {:ok, memory} = Wasmex.memory(instance, :uint8, 0)
      string = "hello, world"
      index = 42
      Wasmex.Memory.write_binary(memory, index, string)

      assert {:ok, [104]} ==
               Wasmex.call_function(instance, :string_first_byte, [index, String.length(string)])
    end
  end

  test "read and manipulate memory in a callback" do
    imports = %{
      env:
        TestHelper.default_imported_functions_env()
        |> Map.put(
          :imported_sum3,
          {:fn, [:i32, :i32, :i32], [:i32],
           fn context, a, b, c ->
             memory = Map.get(context, :memory)
             assert 42 == Wasmex.Memory.get(memory, :uint8, 0, 0)
             Wasmex.Memory.set(memory, :uint8, 0, 0, 23)
             a + b + c
           end}
        )
    }

    instance = start_supervised!({Wasmex, %{bytes: @import_test_bytes, imports: imports}})
    {:ok, memory} = Wasmex.memory(instance, :uint8, 0)
    Wasmex.Memory.set(memory, :uint8, 0, 0, 42)

    # asserts that the byte at memory[0] was set to 42 and then sets it to 23
    {:ok, _} = Wasmex.call_function(instance, :using_imported_sum3, [1, 2, 3])

    assert 23 == Wasmex.Memory.get(memory, :uint8, 0, 0)
  end

  describe "when instantiating with imports" do
    def create_instance_with_atom_imports(_context) do
      imports = %{
        env: TestHelper.default_imported_functions_env()
      }

      instance = start_supervised!({Wasmex, %{bytes: @import_test_bytes, imports: imports}})
      %{instance: instance}
    end

    setup [:create_instance_with_atom_imports]

    test "call_function using_imported_void for void() -> () callback", %{instance: instance} do
      assert {:ok, []} == Wasmex.call_function(instance, :using_imported_void, [])
    end

    test "call_function using_imported_sum3", %{instance: instance} do
      assert {:ok, [44]} == Wasmex.call_function(instance, :using_imported_sum3, [23, 19, 2])
      assert {:ok, [28]} == Wasmex.call_function(instance, :using_imported_sum3, [100, -77, 5])
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

      instance = start_supervised!({Wasmex, %{bytes: @import_test_bytes, imports: imports}})
      %{instance: instance}
    end

    setup [:create_instance_with_string_imports]

    test "call_function using_imported_sum3 with both, string and atom, identifiers", %{
      instance: instance
    } do
      assert {:ok, [6]} == Wasmex.call_function(instance, "using_imported_sum3", [1, 2, 3])
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

      instance = start_supervised!({Wasmex, %{bytes: @import_test_bytes, imports: imports}})
      %{instance: instance}
    end

    setup [:create_instance_with_imports_raising_exceptions]

    test "call_function using_imported_sum3 with both, string and atom, identifiers", %{
      instance: instance
    } do
      assert {:error, reason} = Wasmex.call_function(instance, "using_imported_sum3", [1, 2, 3])

      assert reason =~
               "Error during function excecution: `RuntimeError: the elixir callback threw an exception`."
    end
  end

  test "runnung a WASM/WASI module" do
    imports = %{
      wasi_snapshot_preview1: %{
        proc_exit:
          {:fn, [:i32], [],
           fn _rval ->
             0
           end},
        # "args_get"
        # "args_sizes_get"
        # "fd_prestat_get"
        # "fd_prestat_dir_name"
        # environ_sizes_get:
        #   {:fn, [:i32, :i32], [:i32],
        #    fn environCountPtr, environBufferSizePtr ->
        #      42
        #    end},
        # "environ_get"
        clock_time_get: {:fn, [:i32, :i64, :i32], [:i32], fn %{memory: memory}, clock_id, precision, time_ptr ->
          # 64-bit tv_sec
          Wasmex.Memory.set(memory, time_ptr +  0, 0)
          Wasmex.Memory.set(memory, time_ptr +  1, 0)
          Wasmex.Memory.set(memory, time_ptr +  2, 0)
          Wasmex.Memory.set(memory, time_ptr +  3, 0)
          Wasmex.Memory.set(memory, time_ptr +  4, 0)
          Wasmex.Memory.set(memory, time_ptr +  5, 0)
          Wasmex.Memory.set(memory, time_ptr +  6, 0)
          Wasmex.Memory.set(memory, time_ptr +  7, 0)

          # 64-bit n_sec
          Wasmex.Memory.set(memory, time_ptr +  8, 0)
          Wasmex.Memory.set(memory, time_ptr +  9, 0)
          Wasmex.Memory.set(memory, time_ptr + 10, 0)
          Wasmex.Memory.set(memory, time_ptr + 11, 0)
          Wasmex.Memory.set(memory, time_ptr + 12, 0)
          Wasmex.Memory.set(memory, time_ptr + 13, 0)
          Wasmex.Memory.set(memory, time_ptr + 14, 0)
          Wasmex.Memory.set(memory, time_ptr + 15, 0)

          0
        end},
        random_get:
          {:fn, [:i32, :i32], [:i32],
           fn %{memory: memory}, address, size ->
             Enum.each(0..size, fn(index) ->
               IO.puts("set 0 at #{address + index}")
               Wasmex.Memory.set(memory, address + index, 0)
             end)
             0
           end}
        #
        #
        # Params:
        # fd: __wasi_fd_t,
        # iovs: WasmPtr<__wasi_ciovec_t, Array>,
        # iovs_len: u32,
        # nwritten: WasmPtr<u32>,
        #
        # Returns:
        # __wasi_errno_t
        #
        # See: https://github.com/WebAssembly/WASI/blob/d6eec8647fa819f5d44ac8e7e0d8a3205deedccb/phases/snapshot/docs.md#-fd_writefd-fd-iovs-ciovec_array---errno-size
        # fd_write:
        #   {:fn, [:i32, :i32, :i32, :i32], [:i32],
        #    fn context, fd, iovs, iovs_len, nwritten ->
        #     #  memory = Map.get(context, :memory)
        #     #  IO.puts({:fd, fd})
        #     #  IO.puts({:iovs, iovs})
        #     #  IO.puts({:iovs_len, iovs_len})
        #     #  IO.puts({:nwritten, nwritten})
        #     #  Wasmex.Memory.set(memory, :uint8, 0, nwritten, 23)
        #      0
        #    end},
      }
    }

    wasi = %{
      args: ["hello", "from elixir"],
      env: %{
        "A_NAME_MAPS" => "TO_A_VALUE",
        "THE_TEST_WASI_FILE" => "PRINTS_ALL_ENVS"
      }
    }

    instance =
      start_supervised!({Wasmex, %{bytes: @wasi_test_bytes, imports: imports, wasi: wasi}})

    {:ok, _} = Wasmex.call_function(instance, :_start, [])
  end
end
