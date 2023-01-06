defmodule Wasmex.StoreOrCallerTest do
  use ExUnit.Case, async: true
  import TestHelper, only: [t: 1]
  alias Wasmex.StoreOrCaller

  doctest Wasmex.StoreOrCaller

  describe t(&StoreOrCaller.add_fuel/2) do
    test "adds fuel to a store" do
      {:ok, engine} = Wasmex.Engine.new(%Wasmex.EngineConfig{consume_fuel: true})
      {:ok, store} = Wasmex.Store.new(nil, engine)
      assert StoreOrCaller.add_fuel(store, 10) == :ok
      assert StoreOrCaller.fuel_remaining(store) == {:ok, 10}
    end

    test "adds fuel from within an imported function" do
      {:ok, engine} = Wasmex.Engine.new(%Wasmex.EngineConfig{consume_fuel: true})
      {:ok, store} = Wasmex.Store.new(nil, engine)
      bytes = File.read!(TestHelper.wasm_import_test_file_path())
      {:ok, module} = Wasmex.Module.compile(store, bytes)

      imports = %{
        env:
          Map.merge(TestHelper.default_imported_functions_env(), %{
            imported_sum3:
              {:fn, [:i32, :i32, :i32], [:i32],
               fn context, _a, _b, _c ->
                 # calling using_imported_sum3 spends 34 fuel, we add that and 42 fuel
                 # more to assert that number later
                 :ok = StoreOrCaller.add_fuel(context.caller, 34 + 42)
                 0
               end}
          })
      }

      :ok = StoreOrCaller.add_fuel(store, 10_000)
      pid = start_supervised!({Wasmex, %{store: store, module: module, imports: imports}})
      assert {:ok, [0]} = Wasmex.call_function(pid, "using_imported_sum3", [1, 2, 3])

      # 34 fuel is spent in the function_call, 42 fuel is added synthetically on top
      # within the `imported_sum3` function.
      # We started with 10_000 fuel, so we should have 10_000 - 34 + (34 + 42) = 10_042 fuel left
      assert StoreOrCaller.fuel_remaining(store) == {:ok, 10_042}
    end

    test "errors with a store that has fuel_consumption disabled" do
      {:ok, engine} = Wasmex.Engine.new(%Wasmex.EngineConfig{consume_fuel: false})
      {:ok, store} = Wasmex.Store.new(nil, engine)

      assert StoreOrCaller.add_fuel(store, 1) ==
               {:error, "Could not add fuel to store: fuel is not configured in this store"}
    end
  end

  describe t(&StoreOrCaller.fuel_remaining/1) do
    test "reports fuel remaining with a fresh store" do
      {:ok, engine} = Wasmex.Engine.new(%Wasmex.EngineConfig{consume_fuel: true})
      {:ok, store} = Wasmex.Store.new(nil, engine)
      assert StoreOrCaller.fuel_remaining(store) == {:ok, 0}
    end

    test "reports fuel remaining with a store that has fuel" do
      {:ok, engine} = Wasmex.Engine.new(%Wasmex.EngineConfig{consume_fuel: true})
      {:ok, store} = Wasmex.Store.new(nil, engine)
      assert StoreOrCaller.add_fuel(store, 42) == :ok
      assert StoreOrCaller.fuel_remaining(store) == {:ok, 42}
    end

    test "reports fuel from within an imported function" do
      {:ok, engine} = Wasmex.Engine.new(%Wasmex.EngineConfig{consume_fuel: true})
      {:ok, store} = Wasmex.Store.new(nil, engine)
      bytes = File.read!(TestHelper.wasm_import_test_file_path())
      {:ok, module} = Wasmex.Module.compile(store, bytes)

      imports = %{
        env:
          Map.merge(TestHelper.default_imported_functions_env(), %{
            imported_sum3:
              {:fn, [:i32, :i32, :i32], [:i32],
               fn context, _a, _b, _c ->
                 {:ok, fuel_remaining} = StoreOrCaller.fuel_remaining(context.caller)
                 fuel_remaining
               end}
          })
      }

      :ok = StoreOrCaller.add_fuel(store, 10_000)
      pid = start_supervised!({Wasmex, %{store: store, module: module, imports: imports}})
      assert {:ok, [fuel_remaining]} = Wasmex.call_function(pid, "using_imported_sum3", [1, 2, 3])

      assert fuel_remaining == 9_976
    end

    test "with a store that has fuel_consumption disabled" do
      {:ok, engine} = Wasmex.Engine.new(%Wasmex.EngineConfig{consume_fuel: false})
      {:ok, store} = Wasmex.Store.new(nil, engine)

      assert StoreOrCaller.fuel_remaining(store) == {:ok, 0}
    end
  end

  describe t(&StoreOrCaller.consume_fuel/2) do
    test "consumes fuel on a store that has more fuel than consumed" do
      {:ok, engine} = Wasmex.Engine.new(%Wasmex.EngineConfig{consume_fuel: true})
      {:ok, store} = Wasmex.Store.new(nil, engine)
      assert StoreOrCaller.add_fuel(store, 10) == :ok
      assert StoreOrCaller.consume_fuel(store, 8) == {:ok, 2}
      assert StoreOrCaller.consume_fuel(store, 2) == {:ok, 0}
    end

    test "consumes fuel on a store that has less fuel than consumed" do
      {:ok, engine} = Wasmex.Engine.new(%Wasmex.EngineConfig{consume_fuel: true})
      {:ok, store} = Wasmex.Store.new(nil, engine)
      assert StoreOrCaller.add_fuel(store, 10) == :ok

      assert StoreOrCaller.consume_fuel(store, 18) ==
               {:error, "Could not consume fuel: not enough fuel remaining in store"}
    end

    test "consumes fuel from within an imported function" do
      {:ok, engine} = Wasmex.Engine.new(%Wasmex.EngineConfig{consume_fuel: true})
      {:ok, store} = Wasmex.Store.new(nil, engine)
      bytes = File.read!(TestHelper.wasm_import_test_file_path())
      {:ok, module} = Wasmex.Module.compile(store, bytes)

      imports = %{
        env:
          Map.merge(TestHelper.default_imported_functions_env(), %{
            imported_sum3:
              {:fn, [:i32, :i32, :i32], [:i32],
               fn context, _a, _b, _c ->
                 {:ok, remaining_fuel} = StoreOrCaller.consume_fuel(context.caller, 976)
                 remaining_fuel
               end}
          })
      }

      :ok = StoreOrCaller.add_fuel(store, 10_000)
      pid = start_supervised!({Wasmex, %{store: store, module: module, imports: imports}})

      assert {:ok, [remaining_fuel]} = Wasmex.call_function(pid, "using_imported_sum3", [1, 2, 3])
      assert remaining_fuel == 9_000
    end

    test "errors with a store that has fuel_consumption disabled" do
      {:ok, engine} = Wasmex.Engine.new(%Wasmex.EngineConfig{consume_fuel: false})
      {:ok, store} = Wasmex.Store.new(nil, engine)

      assert StoreOrCaller.consume_fuel(store, 1) ==
               {:error, "Could not consume fuel: not enough fuel remaining in store"}
    end
  end

  describe t(&StoreOrCaller.fuel_consumed/2) do
    test "reports fuel consumption with a fresh store" do
      {:ok, engine} = Wasmex.Engine.new(%Wasmex.EngineConfig{consume_fuel: true})
      {:ok, store} = Wasmex.Store.new(nil, engine)
      assert StoreOrCaller.add_fuel(store, 10) == :ok
      assert StoreOrCaller.fuel_consumed(store) == {:ok, 0}
      assert StoreOrCaller.consume_fuel(store, 2) == {:ok, 8}
      assert StoreOrCaller.fuel_consumed(store) == {:ok, 2}
    end

    test "reports fuel consumption from within an imported function" do
      {:ok, engine} = Wasmex.Engine.new(%Wasmex.EngineConfig{consume_fuel: true})
      {:ok, store} = Wasmex.Store.new(nil, engine)
      bytes = File.read!(TestHelper.wasm_import_test_file_path())
      {:ok, module} = Wasmex.Module.compile(store, bytes)

      imports = %{
        env:
          Map.merge(TestHelper.default_imported_functions_env(), %{
            imported_sum3:
              {:fn, [:i32, :i32, :i32], [:i32],
               fn context, _a, _b, _c ->
                 {:ok, fuel_consumed_in_imported_fun} =
                   StoreOrCaller.fuel_consumed(context.caller)

                 fuel_consumed_in_imported_fun
               end}
          })
      }

      :ok = StoreOrCaller.add_fuel(store, 10_000)
      pid = start_supervised!({Wasmex, %{store: store, module: module, imports: imports}})

      assert {:ok, [fuel_consumed_in_imported_fun]} =
               Wasmex.call_function(pid, "using_imported_sum3", [1, 2, 3])

      assert fuel_consumed_in_imported_fun == 24

      # after full function execution
      assert StoreOrCaller.fuel_consumed(store) == {:ok, 34}
    end

    test "errors with a store that has fuel_consumption disabled" do
      {:ok, engine} = Wasmex.Engine.new(%Wasmex.EngineConfig{consume_fuel: false})
      {:ok, store} = Wasmex.Store.new(nil, engine)

      assert StoreOrCaller.fuel_consumed(store) ==
               {:error, "Could not consume fuel: fuel is not configured in this store"}
    end
  end
end
