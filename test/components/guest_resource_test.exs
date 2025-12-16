defmodule Wasmex.Components.GuestResourceTest do
  use ExUnit.Case, async: false

  alias Wasmex.Components.{Store, Component, Instance, GuestResource}

  defmodule TestCounter do
    use Wasmex.Components.GuestResource,
      wit: File.read!(TestHelper.counter_resource_component_wit_path()),
      resource: "counter"
  end

  setup do
    {:ok, store} = Store.new()
    component_bytes = File.read!(TestHelper.counter_resource_component_file_path())
    {:ok, component} = Component.new(store, component_bytes)
    {:ok, instance} = Instance.new(store, component, %{})

    {:ok, instance: instance}
  end

  describe "compile-time code generation" do
    test "Can start the GenServer", %{instance: instance} do
      {:ok, counter} = TestCounter.start_link(instance, [10])
      assert Process.alive?(counter)

      GenServer.stop(counter)
    end

    test "generates functions", %{instance: instance} do
      {:ok, counter} = TestCounter.start_link(instance, [10])

      assert {:ok, 10} = TestCounter.get_value(counter)
      assert {:ok, 11} = TestCounter.increment(counter)
      assert {:ok, 11} = TestCounter.get_value(counter)

      assert :ok = TestCounter.reset(counter, 5)
      assert {:ok, 5} = TestCounter.get_value(counter)

      assert {:ok, true} = TestCounter.is_in_range(counter, 4, 6)
      assert {:ok, false} = TestCounter.is_in_range(counter, 6, 10)

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
  end

  describe "runtime module creation" do
    test "can create module at runtime", %{instance: instance} do
      # Create a module dynamically
      module_name = :"TestDynamicCounter#{System.unique_integer([:positive])}"

      wit = File.read!(TestHelper.counter_resource_component_wit_path())
      {:ok, ^module_name} = GuestResource.create_module(module_name, wit, "counter")

      {:ok, counter} = apply(module_name, :start_link, [instance, [20]])
      assert {:ok, 20} = apply(module_name, :get_value, [counter])
      assert {:ok, 21} = apply(module_name, :increment, [counter])

      GenServer.stop(counter)
    end

    test "runtime error for non-existent resource" do
      wit = File.read!(TestHelper.counter_resource_component_wit_path())

      assert {:error, :not_found} = GuestResource.create_module(:NonExistent, wit, "nonexistent")
    end

    test "runtime error for invalid wit" do
      wit = """
      invalid-wit
      """

      assert {:error, "Failed to parse WIT" <> _} =
               GuestResource.create_module(:InvalidWit, wit, "any_resource")
    end

    test "using resources with instances from different WIT files fails", %{instance: instance} do
      wit = """
      package wasmex:test;

      interface my-interface {
        resource my-resource {
          constructor();
        }
      }

      world test-world {
        export my-interface;
      }
      """

      module_name = :"TestDynamicCounter#{System.unique_integer([:positive])}"
      {:ok, resource_module} = GuestResource.create_module(module_name, wit, "my-resource")

      Process.flag(:trap_exit, true)
      {:error, reason} = apply(resource_module, :start_link, [instance])

      assert reason ==
               {:resource_creation_failed,
                "Interface segment 'component:my-resource/my-interface' not found"}

      Process.flag(:trap_exit, false)
    end
  end

  describe "edge cases" do
    test "resource creation validates constructor args", %{instance: instance} do
      Process.flag(:trap_exit, true)

      # Empty args fails, as one argument is required to set the initial value
      assert {:error, {:resource_creation_failed, _}} = TestCounter.start_link(instance, [])

      {:ok, counter} = TestCounter.start_link(instance, [42])
      assert {:ok, 42} = TestCounter.get_value(counter)
      GenServer.stop(counter)

      # Multiple args - constructor uses only the first
      {:ok, counter} = TestCounter.start_link(instance, [1, 2])
      assert {:ok, 1} = TestCounter.get_value(counter)
      GenServer.stop(counter)

      Process.flag(:trap_exit, false)
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
