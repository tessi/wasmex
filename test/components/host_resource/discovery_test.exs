defmodule Wasmex.Components.HostResource.DiscoveryTest do
  use ExUnit.Case, async: true

  alias Wasmex.Components.HostResource.Discovery

  test "discovers a versioned imported resource and exact canonical linker names" do
    wit = File.read!(TestHelper.host_resource_component_wit_path())

    assert {:ok,
            %{
              name: "counter",
              interface: "counters",
              interface_path: ["wasmex:host-resources/counters@1.0.0"],
              functions: functions
            }} = Discovery.get_resource_from_wit(wit, :counter)

    assert Enum.find(functions, &(&1.kind == :constructor)) == %{
             wit_name: "constructor",
             canonical_name: "[constructor]counter",
             elixir_name: "constructor",
             kind: :constructor,
             arity: 1,
             has_return: true
           }

    assert Enum.find(functions, &(&1.wit_name == "increment")).canonical_name ==
             "[method]counter.increment"

    assert Enum.find(functions, &(&1.wit_name == "with-value")).canonical_name ==
             "[static]counter.with-value"
  end

  test "discovers a standard WASI resource through a dependency directory" do
    assert {:ok,
            %{
              name: "error",
              interface: "error",
              interface_path: ["wasi:io/error@0.2.12"],
              functions: [
                %{
                  wit_name: "to-debug-string",
                  canonical_name: "[method]error.to-debug-string",
                  elixir_name: "to_debug_string",
                  kind: :method,
                  arity: 0,
                  has_return: true
                }
              ]
            }} =
             Discovery.get_resource_from_path(
               TestHelper.wasi_host_resource_component_wit_path(),
               "error",
               interface: "wasi:io/error@0.2.12"
             )
  end

  test "uses a world import alias verbatim" do
    wit = """
    package example:resources;

    world example {
      import named: interface {
        resource item {
          constructor();
          inspect: func() -> u32;
        }
      }
    }
    """

    assert {:ok, [%{name: "item", interface_path: ["named"]}]} = Discovery.from_wit(wit)
  end

  test "requires an interface when imported resource names are ambiguous" do
    wit = """
    package example:ambiguous;

    interface first {
      resource item {}
    }

    interface second {
      resource item {}
    }

    world example {
      import first;
      import second;
    }
    """

    assert {:error, reason} = Discovery.get_resource_from_wit(wit, "item")
    assert reason =~ "pass the :interface option"

    assert {:ok, %{interface: "second"}} =
             Discovery.get_resource_from_wit(wit, "item", interface: "second")

    assert {:ok, %{interface: "first"}} =
             Discovery.get_resource_from_wit(
               wit,
               "item",
               interface: "example:ambiguous/first"
             )
  end

  test "selects a world explicitly" do
    wit = """
    package example:worlds;

    interface resources {
      resource item {
        constructor();
      }
    }

    world one {
      import resources;
    }

    world two {}
    """

    assert {:error, reason} = Discovery.from_wit(wit)
    assert reason =~ "Failed to select world"
    assert {:ok, [%{name: "item"}]} = Discovery.from_wit(wit, world: "one")
    assert {:ok, []} = Discovery.from_wit(wit, world: "two")
  end

  test "generated modules reject missing callbacks at compile time" do
    module = Module.concat(__MODULE__, "MissingCallbacks#{System.unique_integer([:positive])}")

    code = """
    defmodule #{inspect(module)} do
      use Wasmex.Components.HostResource,
        wit: \"""
        package example:missing;

        interface resources {
          resource item {
            constructor(value: u32);
            value: func() -> u32;
          }
        }

        world example {
          import resources;
        }
        \""",
        resource: "item"
    end
    """

    assert_raise CompileError, ~r/Missing host resource callbacks: new\/1, value\/1/, fn ->
      Code.compile_string(code)
    end
  end

  test "generated modules require exactly one WIT input" do
    module = Module.concat(__MODULE__, "AmbiguousWit#{System.unique_integer([:positive])}")

    code = """
    defmodule #{inspect(module)} do
      use Wasmex.Components.HostResource,
        wit: "package example:inline;",
        wit_path: "wit",
        resource: "item"
    end
    """

    assert_raise CompileError, ~r/Pass either :wit or :wit_path, not both/, fn ->
      Code.compile_string(code)
    end
  end
end
