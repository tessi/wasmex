defmodule Wasmex.StoreOrCallerTest do
  use ExUnit.Case, async: true
  import TestHelper, only: [t: 1]
  alias Wasmex.StoreOrCaller

  doctest Wasmex.StoreOrCaller

  describe t(&StoreOrCaller.set_fuel/2) do
    test "adds fuel to a store" do
      {:ok, engine} = Wasmex.Engine.new(%Wasmex.EngineConfig{consume_fuel: true})
      {:ok, store} = Wasmex.Store.new(nil, engine)
      assert StoreOrCaller.set_fuel(store, 10) == :ok
      assert StoreOrCaller.get_fuel(store) == {:ok, 10}
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
                 # calling using_imported_sum3 spends 10 fuel, we add that and 42 fuel
                 # more to assert that number later
                 :ok = StoreOrCaller.set_fuel(context.caller, 10 + 42)
                 0
               end}
          })
      }

      :ok = StoreOrCaller.set_fuel(store, 10_000)
      pid = start_supervised!({Wasmex, %{store: store, module: module, imports: imports}})
      assert {:ok, [0]} = Wasmex.call_function(pid, "using_imported_sum3", [1, 2, 3])

      # 10 fuel is spent in the function_call, 42 fuel is added synthetically on top
      # within the `imported_sum3` function.
      # We started with 10_000 fuel, but set a different value (10 + 42) in the function - which
      # should leave us with 42 fuel remaining.
      assert StoreOrCaller.get_fuel(store) == {:ok, 42}
    end

    test "errors with a store that has fuel_consumption disabled" do
      {:ok, engine} = Wasmex.Engine.new(%Wasmex.EngineConfig{consume_fuel: false})
      {:ok, store} = Wasmex.Store.new(nil, engine)

      assert StoreOrCaller.set_fuel(store, 1) ==
               {:error, "Could not set fuel: fuel is not configured in this store"}
    end
  end

  describe t(&StoreOrCaller.get_fuel/1) do
    test "reports fuel with a fresh store" do
      {:ok, engine} = Wasmex.Engine.new(%Wasmex.EngineConfig{consume_fuel: true})
      {:ok, store} = Wasmex.Store.new(nil, engine)
      assert StoreOrCaller.get_fuel(store) == {:ok, 0}
    end

    test "reports fuel with a store that has fuel" do
      {:ok, engine} = Wasmex.Engine.new(%Wasmex.EngineConfig{consume_fuel: true})
      {:ok, store} = Wasmex.Store.new(nil, engine)
      assert StoreOrCaller.set_fuel(store, 42) == :ok
      assert StoreOrCaller.get_fuel(store) == {:ok, 42}
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
                 {:ok, fuel} = StoreOrCaller.get_fuel(context.caller)
                 fuel
               end}
          })
      }

      :ok = StoreOrCaller.set_fuel(store, 10_000)
      pid = start_supervised!({Wasmex, %{store: store, module: module, imports: imports}})
      assert {:ok, [fuel]} = Wasmex.call_function(pid, "using_imported_sum3", [1, 2, 3])

      assert fuel == 9_976
    end

    test "with a store that has fuel_consumption disabled" do
      {:ok, engine} = Wasmex.Engine.new(%Wasmex.EngineConfig{consume_fuel: false})
      {:ok, store} = Wasmex.Store.new(nil, engine)

      assert StoreOrCaller.get_fuel(store) ==
               {:error, "Could not get fuel: fuel is not configured in this store"}
    end
  end
end
