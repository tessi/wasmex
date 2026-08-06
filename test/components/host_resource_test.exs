defmodule Wasmex.Components.HostResourceTest do
  use ExUnit.Case, async: false

  alias Wasmex.Components
  alias Wasmex.Components.HostResource

  @interface "wasmex:host-resources/counters@1.0.0"
  @tests "wasmex:host-resources/tests@1.0.0"

  defmodule CounterHost do
    use Wasmex.Components.HostResource,
      wit: File.read!(TestHelper.host_resource_component_wit_path()),
      resource: "counter"

    def new(initial), do: start_counter(initial)
    def with_value(value), do: start_counter(value)
    def make_pair(first, second), do: {start_counter(first), start_counter(second)}
    def maybe(:none), do: :none
    def maybe({:some, value}), do: {:some, start_counter(value)}

    def increment({counter, _drops}),
      do: Agent.get_and_update(counter, &{&1 + 1, &1 + 1})

    def value({counter, _drops}), do: Agent.get(counter, & &1)

    def add_other({counter, _drops}, {other, _other_drops}),
      do: Agent.get(counter, & &1) + Agent.get(other, & &1)

    def take_other({counter, _drops}, {other, _other_drops}) do
      value = Agent.get(counter, & &1) + Agent.get(other, & &1)
      Agent.stop(other)
      value
    end

    def drop({counter, drops}) do
      Agent.update(drops, &(&1 + 1))
      if Process.alive?(counter), do: Agent.stop(counter)
    end

    defp start_counter(initial) do
      drops = Process.whereis(:host_resource_drops)
      {:ok, counter} = Agent.start_link(fn -> initial end)
      {counter, drops}
    end
  end

  defmodule LabelHost do
    use Wasmex.Components.HostResource,
      wit: File.read!(TestHelper.host_resource_component_wit_path()),
      resource: "label"

    def new(text), do: {text, Process.whereis(:host_resource_drops)}
    def text({text, _drops}), do: text
    def drop({_text, drops}), do: Agent.update(drops, &(&1 + 1))
  end

  setup do
    {:ok, drops} = Agent.start_link(fn -> 0 end, name: :host_resource_drops)

    imports = HostResource.merge_imports([CounterHost, LabelHost])
    {:ok, drops: drops, imports: imports}
  end

  test "links constructors, methods, static functions, borrows, ownership, and destructors", %{
    drops: drops,
    imports: imports
  } do
    component = start_component(imports)

    assert {:ok, 12} = Components.call_function(component, [@tests, "run-basic"], [5])
    assert {:ok, 13} = Components.call_function(component, [@tests, "run-borrow"], [6, 7])
    assert {:ok, 17} = Components.call_function(component, [@tests, "run-take"], [8, 9])
    assert {:ok, 10} = Components.call_function(component, [@tests, "run-static"], [10])
    assert {:ok, 7} = Components.call_function(component, [@tests, "run-pair"], [3, 4])

    assert {:ok, {:some, 11}} =
             Components.call_function(component, [@tests, "run-maybe"], [{:some, 11}])

    assert {:ok, :none} = Components.call_function(component, [@tests, "run-maybe"], [:none])
    assert {:ok, "host"} = Components.call_function(component, [@tests, "run-label"], ["host"])

    assert Agent.get(drops, & &1) == 9
  end

  test "serializes concurrent resource calls through the component server", %{
    drops: drops,
    imports: imports
  } do
    component = start_component(imports)

    results =
      1..20
      |> Enum.map(fn value ->
        Task.async(fn -> Components.call_function(component, [@tests, "run-basic"], [value]) end)
      end)
      |> Task.await_many()

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert Agent.get(drops, & &1) == 20
  end

  test "merges generated resources with freestanding import maps" do
    freestanding = fn value -> value end

    imports =
      HostResource.merge_imports([
        CounterHost,
        %{@interface => %{"echo" => {:fn, freestanding}}}
      ])

    assert %{
             @interface => %{
               "counter" => {:resource, _drop},
               "echo" => {:fn, ^freestanding}
             }
           } = imports
  end

  test "invalid callback results trap the call without terminating the server", %{
    imports: imports
  } do
    imports =
      put_in(
        imports,
        [@interface, "[method]counter.value"],
        {:fn, fn _counter -> "not a u32" end}
      )

    component = start_component(imports)

    assert {:error, reason} = Components.call_function(component, [@tests, "run-basic"], [5])
    assert is_binary(reason) and reason != ""
    assert Process.alive?(component)
  end

  test "callback exceptions trap the call without terminating the server", %{imports: imports} do
    imports =
      put_in(
        imports,
        [@interface, "[method]counter.increment"],
        {:fn, fn _counter -> raise "increment failed" end}
      )

    component = start_component(imports)

    assert {:error, reason} = Components.call_function(component, [@tests, "run-basic"], [5])
    assert is_binary(reason) and reason != ""
    assert Process.alive?(component)
  end

  test "destructor exceptions trap the active call without terminating the server", %{
    imports: imports
  } do
    imports =
      put_in(
        imports,
        [@interface, "counter"],
        {:resource, fn _counter -> raise "drop failed" end}
      )

    component = start_component(imports)

    assert {:error, reason} = Components.call_function(component, [@tests, "run-basic"], [5])
    assert is_binary(reason) and reason != ""
    assert Process.alive?(component)
  end

  defp start_component(imports) do
    start_supervised!(
      {Components,
       bytes: File.read!(TestHelper.host_resource_component_file_path()), imports: imports}
    )
  end
end
