defmodule Wasmex.Components.GuestResource.DiscoveryTest do
  use ExUnit.Case, async: true

  alias Wasmex.Components.GuestResource.Discovery

  describe "from_wit/1" do
    test "returns a list of resources from a wit file" do
      wit = File.read!(TestHelper.counter_resource_component_wit_path())
      {:ok, resources} = Discovery.from_wit(wit)

      assert [
               %{
                 name: :counter,
                 interface: :types,
                 functions: [
                   %{
                     wit_name: :constructor,
                     elixir_name: :constructor,
                     arity: 1,
                     has_return: true
                   },
                   %{wit_name: :increment, elixir_name: :increment, arity: 1, has_return: true},
                   %{wit_name: :"get-value", elixir_name: :get_value, arity: 1, has_return: true},
                   %{wit_name: :reset, elixir_name: :reset, arity: 2, has_return: false},
                   %{
                     wit_name: :"is-in-range",
                     elixir_name: :is_in_range,
                     arity: 3,
                     has_return: true
                   }
                 ]
               }
             ] = resources
    end

    test "valid WIT with no resources defined" do
      wit = """
      package wasmex:test;

      world invalid-wit { }
      """

      assert {:ok, []} = Discovery.from_wit(wit)
    end

    test "returns error on invalid WIT contents" do
      wit = """
      package wasmex:test;

      invalid-wit
      """

      assert {:error, "Failed to parse WIT" <> _} = Discovery.from_wit(wit)
    end

    test "returns more than one resource" do
      wit = """
      package wasmex:test;

      interface my-interface {
        resource resource-one {
          constructor();
        }

        resource resource-two {
          constructor();
        }
      }

      world test-world {
        export my-interface;
      }
      """

      {:ok, resources} = Discovery.from_wit(wit)

      assert [
               %{
                 name: :"resource-one",
                 interface: :"my-interface",
                 functions: [
                   %{
                     wit_name: :constructor,
                     elixir_name: :constructor,
                     arity: 0,
                     has_return: true
                   }
                 ]
               },
               %{
                 name: :"resource-two",
                 interface: :"my-interface",
                 functions: [
                   %{
                     wit_name: :constructor,
                     elixir_name: :constructor,
                     arity: 0,
                     has_return: true
                   }
                 ]
               }
             ] = resources
    end
  end

  describe "get_resource_from_wit/2" do
    test "returns the resource from a wit file if it exists" do
      wit = File.read!(TestHelper.counter_resource_component_wit_path())
      {:error, :not_found} = Discovery.get_resource_from_wit(wit, :"non-existent-resource")
      {:ok, resource} = Discovery.get_resource_from_wit(wit, :counter)

      assert %{
               name: :counter,
               interface: :types,
               functions: [
                 %{
                   wit_name: :constructor,
                   elixir_name: :constructor,
                   arity: 1,
                   has_return: true
                 },
                 %{wit_name: :increment, elixir_name: :increment, arity: 1, has_return: true},
                 %{wit_name: :"get-value", elixir_name: :get_value, arity: 1, has_return: true},
                 %{wit_name: :reset, elixir_name: :reset, arity: 2, has_return: false},
                 %{
                   wit_name: :"is-in-range",
                   elixir_name: :is_in_range,
                   arity: 3,
                   has_return: true
                 }
               ]
             } = resource
    end

    test "returns error on invalid WIT contents" do
      wit = """
      package wasmex:test;

      invalid-wit
      """

      assert {:error,
              "Failed to parse WIT: expected `world`, `interface` or `use`, found an identifier\n     --> wit:3:1" <>
                _} =
               Discovery.get_resource_from_wit(wit, :any_resource)
    end

    test "returns error on invalid WIT contents with custom file path, if given the path option" do
      wit = """
      package wasmex:test;

      invalid-wit
      """

      assert {:error,
              "Failed to parse WIT: expected `world`, `interface` or `use`, found an identifier\n     --> some/custom/path.wit:3:1" <>
                _} =
               Discovery.get_resource_from_wit(wit, :any_resource, path: "some/custom/path.wit")
    end

    test "returns more than one resource" do
      wit = """
      package wasmex:test;

      interface my-interface {
        resource resource-one {
          constructor();
        }

        resource resource-two {
          constructor();
        }
      }

      world test-world {
        export my-interface;
      }
      """

      {:ok, resource} = Discovery.get_resource_from_wit(wit, :"resource-one")

      assert %{
               name: :"resource-one",
               interface: :"my-interface",
               functions: [
                 %{
                   wit_name: :constructor,
                   elixir_name: :constructor,
                   arity: 0,
                   has_return: true
                 }
               ]
             } = resource

      {:ok, resource} = Discovery.get_resource_from_wit(wit, :"resource-two")

      assert %{
               name: :"resource-two",
               interface: :"my-interface",
               functions: [
                 %{
                   wit_name: :constructor,
                   elixir_name: :constructor,
                   arity: 0,
                   has_return: true
                 }
               ]
             } = resource
    end
  end
end
