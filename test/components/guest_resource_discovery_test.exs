defmodule Wasmex.Components.GuestResource.DiscoveryTest do
  use ExUnit.Case, async: false

  alias Wasmex.Components.GuestResource.Discovery

  @counter_wit_path "test/component_fixtures/counter-component/wit/world.wit"

  describe "from_wit/1" do
    test "extracts resources from WIT file" do
      {:ok, resources} = Discovery.from_wit(@counter_wit_path)

      assert length(resources) > 0

      # Find the counter resource
      counter = Enum.find(resources, &(&1.name == :counter))
      assert counter != nil
      assert counter.interface == :types
      assert is_list(counter.methods)
    end

    test "returns error for non-existent file" do
      {:error, {:file_read_error, :enoent}} = Discovery.from_wit("nonexistent.wit")
    end
  end

  describe "functions_from_wit/1" do
    test "extracts functions from WIT file" do
      {:ok, functions} = Discovery.functions_from_wit(@counter_wit_path)

      # Should include exported functions
      assert is_map(functions) or is_list(functions)
    end
  end

  describe "get_resource_from_wit/2" do
    test "gets specific resource by name" do
      {:ok, counter} = Discovery.get_resource_from_wit(@counter_wit_path, :counter)

      assert counter.name == :counter
      assert counter.interface == :types
      assert is_list(counter.methods)
    end

    test "accepts string resource name" do
      {:ok, counter} = Discovery.get_resource_from_wit(@counter_wit_path, "counter")

      assert counter.name == :counter
    end

    test "returns not_found for non-existent resource" do
      {:error, :not_found} = Discovery.get_resource_from_wit(@counter_wit_path, :nonexistent)
    end
  end

  describe "get_resource_methods_from_wit/2" do
    test "lists methods for a resource" do
      {:ok, methods} = Discovery.get_resource_methods_from_wit(@counter_wit_path, :counter)

      assert is_list(methods)

      # Methods should be tuples of {name, arity, has_return}
      assert Enum.all?(methods, fn
               {name, arity, has_return}
               when is_atom(name) and is_integer(arity) and is_boolean(has_return) ->
                 true

               _ ->
                 false
             end)
    end

    test "returns error for non-existent resource" do
      {:error, :not_found} =
        Discovery.get_resource_methods_from_wit(@counter_wit_path, :nonexistent)
    end
  end

  describe "resource_exists_in_wit?/2" do
    test "returns true for existing resource" do
      assert Discovery.resource_exists_in_wit?(@counter_wit_path, :counter)
    end

    test "returns false for non-existent resource" do
      refute Discovery.resource_exists_in_wit?(@counter_wit_path, :nonexistent)
    end

    test "returns false for non-existent file" do
      refute Discovery.resource_exists_in_wit?("nonexistent.wit", :counter)
    end
  end

  describe "generate_paths/2" do
    test "generates correct paths for a resource" do
      resource_info = %{
        name: :counter,
        interface: :types,
        methods: []
      }

      paths = Discovery.generate_paths(resource_info)

      assert paths.constructor_path == ["component:counter/types", "counter"]
      assert paths.interface_path == ["component:counter/types"]
    end

    test "accepts custom package option" do
      resource_info = %{
        name: :counter,
        interface: :types,
        methods: []
      }

      paths = Discovery.generate_paths(resource_info, package: "test")

      assert paths.constructor_path == ["test:counter/types", "counter"]
      assert paths.interface_path == ["test:counter/types"]
    end
  end

  describe "integration" do
    test "full discovery workflow with counter component" do
      # Parse WIT file
      {:ok, resources} = Discovery.from_wit(@counter_wit_path)

      # Find counter resource
      counter = Enum.find(resources, &(&1.name == :counter))
      assert counter != nil

      # Generate paths
      paths = Discovery.generate_paths(counter)

      # Verify the paths match what we expect for the counter component
      assert paths.constructor_path == ["component:counter/types", "counter"]
      assert paths.interface_path == ["component:counter/types"]

      # Check methods
      assert length(counter.methods) > 0

      # Verify expected methods are present (as tuples)
      method_names = Enum.map(counter.methods, fn {name, _, _} -> name end)
      assert :increment in method_names or :increment in method_names
      assert :"get-value" in method_names or :get_value in method_names
      assert :reset in method_names
    end
  end
end
