defmodule Wasmex.Components.GuestResource.DiscoveryTest do
  use ExUnit.Case, async: true

  alias Wasmex.Components.GuestResource.Discovery

  test "discovers the real versioned interface export path and resource methods" do
    wit = File.read!(TestHelper.guest_resource_component_wit_path())

    assert {:ok,
            %{
              name: "accumulator",
              interface: "counters",
              interface_path: ["wasmex:resources/counters@1.2.3"],
              constructor_path: ["wasmex:resources/counters@1.2.3", "accumulator"],
              functions: functions
            }} = Discovery.get_resource_from_wit(wit, "accumulator")

    assert Enum.find(functions, &(&1.wit_name == "constructor")) == %{
             wit_name: "constructor",
             elixir_name: "constructor",
             kind: :constructor,
             arity: 1,
             has_return: true
           }

    assert Enum.find(functions, &(&1.wit_name == "with-value")).kind == :static
    assert Enum.find(functions, &(&1.wit_name == "add-other")).arity == 1
    refute Enum.find(functions, &(&1.wit_name == "reset")).has_return
  end

  test "uses a world export alias verbatim" do
    wit = """
    package example:resources;

    world example {
      export named: interface {
        resource item {
          constructor();
          inspect: func() -> u32;
        }
      }
    }
    """

    assert {:ok,
            [
              %{
                name: "item",
                interface: "named",
                interface_path: ["named"],
                constructor_path: ["named", "item"]
              }
            ]} = Discovery.from_wit(wit)
  end

  test "reports static and async resource function kinds without implicit self arity" do
    wit = """
    package example:resources;

    interface items {
      resource item {
        constructor();
        create: static func(value: u32) -> item;
        inspect: func() -> u32;
      }
    }

    world example {
      export items;
    }
    """

    assert {:ok, [%{functions: functions}]} = Discovery.from_wit(wit)

    assert Enum.find(functions, &(&1.wit_name == "create")) == %{
             wit_name: "create",
             elixir_name: "create",
             kind: :static,
             arity: 1,
             has_return: true
           }

    assert Enum.find(functions, &(&1.wit_name == "inspect")).arity == 0
  end

  test "returns no resources for a world without resource exports" do
    assert {:ok, []} =
             Discovery.from_wit("""
             package example:empty;
             world example {}
             """)
  end

  test "returns parser errors and supports diagnostic paths" do
    assert {:error, reason} =
             Discovery.from_wit("not-wit", path: "fixtures/broken.wit")

    assert reason =~ "Failed to parse WIT"
    assert reason =~ "fixtures/broken.wit"
  end

  test "finds a resource by atom or string name" do
    wit = File.read!(TestHelper.guest_resource_component_wit_path())

    assert {:ok, %{name: "accumulator"}} =
             Discovery.get_resource_from_wit(wit, :accumulator)

    assert {:ok, %{name: "accumulator"}} =
             Discovery.get_resource_from_wit(wit, "accumulator")

    assert {:error, :not_found} =
             Discovery.get_resource_from_wit(wit, "missing")
  end
end
