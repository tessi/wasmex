defmodule Wasmex.Components.GuestResourceTest do
  use ExUnit.Case, async: false

  alias Wasmex.Components.{Store, Component, Instance, GuestResource}

  @counter_wasm_path "test/component_fixtures/counter-component/target/wasm32-wasip1/release/counter_component.wasm"
  @counter_wit_path "test/component_fixtures/counter-component/wit/world.wit"

  # Define a test client module using the macro
  defmodule TestCounter do
    use Wasmex.Components.GuestResource,
      wit: "test/component_fixtures/counter-component/wit/world.wit",
      resource: "counter"
  end

  setup do
    unless File.exists?(@counter_wasm_path) do
      raise "Counter component not found. Please build it first."
    end

    {:ok, store} = Store.new()
    component_bytes = File.read!(@counter_wasm_path)
    {:ok, component} = Component.new(store, component_bytes)
    {:ok, instance} = Instance.new(store, component, %{})

    {:ok, store: store, instance: instance}
  end

  describe "compile-time code generation" do
    test "generates start_link function", %{instance: instance} do
      # TestCounter should have start_link/3
      assert function_exported?(TestCounter, :start_link, 3)

      # Should be able to start a resource
      {:ok, counter} = TestCounter.start_link(instance, [10])
      assert Process.alive?(counter)

      # Clean up
      GenServer.stop(counter)
    end

    test "generates method functions", %{instance: instance} do
      # Check that methods were generated with correct arities
      # No params
      assert function_exported?(TestCounter, :increment, 1)
      # No params
      assert function_exported?(TestCounter, :get_value, 1)
      # One param
      assert function_exported?(TestCounter, :reset, 2)

      # Start a counter
      {:ok, counter} = TestCounter.start_link(instance, [10])

      # Test generated methods
      assert {:ok, 10} = TestCounter.get_value(counter)
      assert {:ok, 11} = TestCounter.increment(counter)
      assert {:ok, 11} = TestCounter.get_value(counter)
      # Single argument, not a list
      assert :ok = TestCounter.reset(counter, 5)
      assert {:ok, 5} = TestCounter.get_value(counter)

      GenServer.stop(counter)
    end

    test "generates child_spec for supervision", %{instance: instance} do
      assert function_exported?(TestCounter, :child_spec, 1)

      # Should work with Supervisor
      children = [
        {TestCounter, [instance, [0], [name: :supervised_counter]]}
      ]

      {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)

      # Should be able to use the supervised counter
      assert {:ok, 0} = TestCounter.get_value(:supervised_counter)
      assert {:ok, 1} = TestCounter.increment(:supervised_counter)

      Supervisor.stop(sup)
    end

    test "method names are converted from kebab-case to snake_case" do
      # get-value should become get_value
      assert function_exported?(TestCounter, :get_value, 1)
      refute function_exported?(TestCounter, :"get-value", 1)
    end
  end

  describe "runtime module creation" do
    test "can create module at runtime", %{instance: instance} do
      # Create a module dynamically
      module_name = :"TestDynamicCounter#{System.unique_integer([:positive])}"

      {:ok, ^module_name} =
        GuestResource.create_module(
          module_name,
          @counter_wit_path,
          "counter"
        )

      # Should have the expected functions
      assert function_exported?(module_name, :start_link, 3)
      # No params
      assert function_exported?(module_name, :increment, 1)
      # No params
      assert function_exported?(module_name, :get_value, 1)
      # One param
      assert function_exported?(module_name, :reset, 2)

      # Should work
      {:ok, counter} = apply(module_name, :start_link, [instance, [20]])
      assert {:ok, 20} = apply(module_name, :get_value, [counter])
      assert {:ok, 21} = apply(module_name, :increment, [counter])

      GenServer.stop(counter)
    end

    test "runtime module generates expected functions" do
      module_name = :"TestInfoCounter#{System.unique_integer([:positive])}"

      {:ok, ^module_name} =
        GuestResource.create_module(
          module_name,
          @counter_wit_path,
          "counter"
        )

      # Check that the expected functions are generated
      assert function_exported?(module_name, :start_link, 2)
      assert function_exported?(module_name, :start_link, 3)
      assert function_exported?(module_name, :increment, 1)
      assert function_exported?(module_name, :get_value, 1)
      assert function_exported?(module_name, :reset, 2)
    end
  end

  describe "error handling" do
    test "compile-time error for non-existent WIT file" do
      # This would normally cause a compile error
      # We can't easily test this in runtime tests
      # but the macro includes proper error handling
      assert {:error, {:file_read_error, :enoent}} =
               Wasmex.Components.GuestResource.Discovery.get_resource_from_wit(
                 "nonexistent.wit",
                 "counter"
               )
    end

    test "runtime error for non-existent resource" do
      assert {:error, :not_found} =
               GuestResource.create_module(
                 :NonExistent,
                 @counter_wit_path,
                 "nonexistent"
               )
    end
  end

  describe "edge cases" do
    test "resource creation validates constructor args", %{instance: instance} do
      # The counter constructor requires exactly 1 argument
      Process.flag(:trap_exit, true)

      # Empty args should fail
      result = TestCounter.start_link(instance, [])
      assert {:error, {:resource_creation_failed, _}} = result

      # Single arg should work
      {:ok, counter} = TestCounter.start_link(instance, [42])
      assert {:ok, 42} = TestCounter.get_value(counter)

      # Multiple args - constructor uses only the first
      {:ok, counter2} = TestCounter.start_link(instance, [1, 2])
      assert {:ok, 1} = TestCounter.get_value(counter2)

      Process.flag(:trap_exit, false)

      GenServer.stop(counter)
      GenServer.stop(counter2)
    end

    test "handles concurrent calls correctly", %{instance: instance} do
      {:ok, counter} = TestCounter.start_link(instance, [0])

      # Launch many concurrent increments
      tasks =
        for _ <- 1..100 do
          Task.async(fn -> TestCounter.increment(counter) end)
        end

      results = Task.await_many(tasks)

      # All should succeed
      assert Enum.all?(results, fn
               {:ok, _} -> true
               _ -> false
             end)

      # Final value should be 100
      assert {:ok, 100} = TestCounter.get_value(counter)

      GenServer.stop(counter)
    end
  end
end
