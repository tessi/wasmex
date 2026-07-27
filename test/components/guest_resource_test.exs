defmodule Wasmex.Components.GuestResourceTest do
  use ExUnit.Case, async: false

  alias Wasmex.Components.{Component, GuestResource, Instance, Store}
  alias Wasmex.Components.GuestResource.Discovery

  defmodule Accumulator do
    use Wasmex.Components.GuestResource,
      wit: File.read!(TestHelper.guest_resource_component_wit_path()),
      resource: "accumulator"
  end

  defmodule Label do
    use Wasmex.Components.GuestResource,
      wit: File.read!(TestHelper.guest_resource_component_wit_path()),
      resource: "label"
  end

  defmodule Factory do
    use Wasmex.Components.GuestResource,
      wit: File.read!(TestHelper.guest_resource_component_wit_path()),
      resource: "factory"
  end

  setup do
    instance = new_instance()

    {:ok, instance: instance}
  end

  test "constructs and calls a low-level resource without hard-coded names or packages", %{
    instance: instance
  } do
    wit = File.read!(TestHelper.guest_resource_component_wit_path())
    {:ok, metadata} = Discovery.get_resource_from_wit(wit, "accumulator")
    {:ok, resource} = GuestResource.new(instance, metadata.constructor_path, [10])

    assert {:ok, 10} = GuestResource.call(resource, :method, "get-value")
    assert {:ok, 11} = GuestResource.call(resource, :method, :increment)
    assert :ok = GuestResource.call(resource, :method, :reset, [7])
    assert {:ok, true} = GuestResource.call(resource, :method, "is-in-range", [6, 8])
    assert :ok = GuestResource.drop(resource)
  end

  test "generated resource modules expose arity-aware snake-case functions", %{
    instance: instance
  } do
    {:ok, accumulator} = Accumulator.new(instance, 20)

    assert {:ok, 20} = Accumulator.get_value(accumulator)
    assert {:ok, 21} = Accumulator.increment(accumulator)
    assert :ok = Accumulator.reset(accumulator, 5)
    assert {:ok, true} = Accumulator.is_in_range(accumulator, 4, 6)
    assert {:ok, false} = Accumulator.is_in_range(accumulator, 6, 10)

    assert {:ok, %GuestResource{} = another} = Accumulator.with_value(instance, 100)
    assert {:ok, 100} = Accumulator.get_value(another)
    assert :ok = Accumulator.drop(another)
    assert :ok = Accumulator.drop(accumulator)
  end

  test "validates constructor and method argument counts exactly", %{instance: instance} do
    path = ["wasmex:resources/counters@1.2.3", "accumulator"]

    assert {:error, reason} = GuestResource.new(instance, path, [])
    assert reason =~ "Expected 1 guest resource arguments, got 0"

    assert {:error, reason} = GuestResource.new(instance, path, [1, 2])
    assert reason =~ "Expected 1 guest resource arguments, got 2"

    {:ok, resource} = GuestResource.new(instance, path, [1])
    assert {:error, reason} = GuestResource.call(resource, :method, "reset", [])
    assert reason =~ "Expected 1 guest resource arguments, got 0"
  end

  test "dropping is idempotent and prevents later calls", %{instance: instance} do
    {:ok, resource} =
      GuestResource.new(
        instance,
        ["wasmex:resources/counters@1.2.3", "accumulator"],
        [1]
      )

    assert :ok = GuestResource.drop(resource)
    assert :ok = GuestResource.drop(resource)

    assert {:error, "Guest resource has already been dropped or moved"} =
             GuestResource.call(resource, :method, "get-value")

    assert {:ok, %GuestResource{} = another} = Accumulator.with_value(instance, 2)
    assert :ok = Accumulator.drop(another)
  end

  test "serializes concurrent method calls through the component Store", %{instance: instance} do
    {:ok, accumulator} = Accumulator.new(instance, 0)

    results =
      1..50
      |> Enum.map(fn _ -> Task.async(fn -> Accumulator.increment(accumulator) end) end)
      |> Task.await_many()

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert {:ok, 50} = Accumulator.get_value(accumulator)
  end

  test "passes borrowed and owned resources with move semantics", %{instance: instance} do
    {:ok, accumulator} = Accumulator.new(instance, 10)
    {:ok, other} = Accumulator.new(instance, 5)

    assert {:ok, 15} = Accumulator.add_other(accumulator, other)
    assert {:ok, 5} = Accumulator.get_value(other)

    assert {:error, _reason} = Accumulator.take_other_with(accumulator, other, "invalid")
    assert {:ok, 5} = Accumulator.get_value(other)

    assert {:error, reason} = Accumulator.take_two(accumulator, other, other)
    assert reason =~ "cannot be moved more than once"
    assert {:ok, 5} = Accumulator.get_value(other)

    assert {:error, reason} = Accumulator.take_other(accumulator, accumulator)
    assert reason =~ "cannot move its own receiver"
    assert {:ok, 10} = Accumulator.get_value(accumulator)

    assert {:ok, 15} = Accumulator.take_other(accumulator, other)

    assert {:error, "Guest resource has already been dropped or moved"} =
             Accumulator.get_value(other)

    {:ok, label} = Label.new(instance, "not an accumulator")

    assert {:error, reason} = Accumulator.add_other(accumulator, label)
    assert reason =~ "wrong resource type"
    assert {:ok, "not an accumulator"} = Label.text(label)
  end

  test "wraps the actual type of direct and nested returned resources", %{instance: instance} do
    {:ok, accumulator} = Accumulator.new(instance, 1)

    assert {:ok, label} = Accumulator.make_label(accumulator, "direct")
    assert {:ok, "direct"} = Label.text(label)

    assert {:ok, {:some, nested_label}} = Accumulator.maybe_label(accumulator, {:some, "nested"})
    assert {:ok, "nested"} = Label.text(nested_label)
    assert {:ok, :none} = Accumulator.maybe_label(accumulator, :none)

    assert {:ok, {pair_accumulator, pair_label}} = Factory.make_pair(instance, 8, "pair")
    assert {:ok, 8} = Accumulator.get_value(pair_accumulator)
    assert {:ok, "pair"} = Label.text(pair_label)
  end

  test "supports resources that only export static functions", %{instance: instance} do
    refute function_exported?(Factory, :new, 1)

    assert {:ok, accumulator} = Factory.make_accumulator(instance, 12)
    assert {:ok, 12} = Accumulator.get_value(accumulator)

    assert {:ok, label} = Factory.make_label(instance, "static")
    assert {:ok, "static"} = Label.text(label)
  end

  test "accepts a component server directly for constructors and static functions" do
    component =
      start_supervised!(
        {Wasmex.Components, bytes: File.read!(TestHelper.guest_resource_component_file_path())}
      )

    assert %Instance{} = Wasmex.Components.instance(component)
    assert {:ok, accumulator} = Accumulator.new(component, 20)
    assert {:ok, 21} = Accumulator.increment(accumulator)
    assert {:ok, label} = Factory.make_label(component, "server")
    assert {:ok, "server"} = Label.text(label)
  end

  test "interrupts constructors, methods, and destructors at their timeout", %{
    instance: instance
  } do
    assert {:error, :timeout} = Accumulator.new(instance, 4_294_967_295, timeout: 10)

    method_instance = new_instance()
    {:ok, accumulator} = Accumulator.new(method_instance, 1)
    assert {:error, :timeout} = Accumulator.hang(accumulator, timeout: 10)

    drop_instance = new_instance()
    {:ok, slow_drop} = Accumulator.new(drop_instance, 4_294_967_294)
    assert {:error, :timeout} = Accumulator.drop(slow_drop, timeout: 10)
  end

  test "runs destructors for explicit drops and garbage-collected handles", %{
    instance: instance
  } do
    assert :ok = Factory.reset_drop_count(instance)

    {:ok, explicit} = Accumulator.new(instance, 1)
    assert :ok = Accumulator.drop(explicit)
    assert {:ok, 1} = Factory.drop_count(instance)

    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        {:ok, %GuestResource{}} = Accumulator.new(instance, 2)
        send(parent, :resource_created)
      end)

    assert_receive :resource_created
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    assert eventually(fn -> Factory.drop_count(instance) == {:ok, 2} end)
  end

  test "selects a world explicitly when WIT contains multiple worlds" do
    wit = """
    package example:worlds;

    interface resources {
      resource first {
        constructor();
      }
    }

    world one {
      export resources;
    }

    world two {}
    """

    assert {:error, reason} = Discovery.from_wit(wit)
    assert reason =~ "Failed to select world"
    assert {:ok, [%{name: "first"}]} = Discovery.from_wit(wit, world: "one")
    assert {:ok, []} = Discovery.from_wit(wit, world: "two")
  end

  test "reports incorrect interface and resource paths", %{instance: instance} do
    assert {:error, reason} = GuestResource.new(instance, [], [1])
    assert reason =~ "must contain an exported interface and a resource name"

    assert {:error, reason} = GuestResource.new(instance, ["accumulator"], [1])
    assert reason =~ "must contain an exported interface and a resource name"

    assert {:error, reason} =
             GuestResource.new(instance, ["wrong:package/types", "accumulator"], [1])

    assert reason =~ "Export path segment `wrong:package/types` was not found"

    assert {:error, reason} =
             GuestResource.new(
               instance,
               ["wasmex:resources/counters@1.2.3", "counter"],
               [1]
             )

    assert reason =~ "Guest resource function `[constructor]counter` was not found"
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false

  defp new_instance do
    {:ok, store} = Store.new()
    bytes = File.read!(TestHelper.guest_resource_component_file_path())
    {:ok, component} = Component.new(store, bytes)
    {:ok, instance} = Instance.new(store, component, %{})
    instance
  end
end
