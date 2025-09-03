defmodule Wasmex.Components.GuestResource.Discovery do
  @moduledoc """
  Discovery and introspection of guest resources exported by WASM components.

  This module provides tools to discover what resources a component exports
  and what methods those resources provide by parsing WIT files.
  """

  @doc """
  Extracts resource information from a WIT file.

  ## Parameters
    * `wit_path` - Path to the WIT file

  ## Returns
    * `{:ok, resources}` - List of resources with their metadata
    * `{:error, reason}` - If parsing failed

  ## Example

      {:ok, resources} = Discovery.from_wit("component.wit")
      # => [
      #      %{
      #        name: :counter,
      #        interface: :types,
      #        methods: [
      #          {:increment, 1, true},
      #          {:get_value, 1, true},
      #          {:reset, 2, false}
      #        ]
      #      }
      #    ]
  """
  def from_wit(wit_path) when is_binary(wit_path) do
    case File.read(wit_path) do
      {:ok, wit_contents} ->
        resources = Wasmex.Native.wit_exported_resources(wit_path, wit_contents)

        parsed_resources =
          resources
          |> Enum.map(fn {name, interface, methods} ->
            %{
              name: name,
              interface: interface,
              methods: methods
            }
          end)

        {:ok, parsed_resources}

      {:error, reason} ->
        {:error, {:file_read_error, reason}}
    end
  rescue
    error -> {:error, error}
  end

  @doc """
  Extracts function exports from a WIT file.

  This is a convenience wrapper around the native WIT parser for functions.

  ## Parameters
    * `wit_path` - Path to the WIT file

  ## Returns
    * `{:ok, functions}` - Map of function names to arities
    * `{:error, reason}` - If parsing failed
  """
  def functions_from_wit(wit_path) when is_binary(wit_path) do
    case File.read(wit_path) do
      {:ok, wit_contents} ->
        functions = Wasmex.Native.wit_exported_functions(wit_path, wit_contents)
        {:ok, functions}

      {:error, reason} ->
        {:error, {:file_read_error, reason}}
    end
  rescue
    error -> {:error, error}
  end

  @doc """
  Gets detailed information about a specific resource from WIT.

  ## Parameters
    * `wit_path` - Path to the WIT file
    * `resource_name` - Name of the resource (as atom or string)

  ## Returns
    * `{:ok, resource_info}` - Resource information if found
    * `{:error, :not_found}` - If resource not found
    * `{:error, reason}` - If parsing failed
  """
  def get_resource_from_wit(wit_path, resource_name) when is_binary(wit_path) do
    resource_atom =
      case resource_name do
        name when is_atom(name) -> name
        name when is_binary(name) -> String.to_atom(name)
      end

    case from_wit(wit_path) do
      {:ok, resources} ->
        case Enum.find(resources, &(&1.name == resource_atom)) do
          nil -> {:error, :not_found}
          resource -> {:ok, resource}
        end

      error ->
        error
    end
  end

  @doc """
  Lists all methods for a specific resource from WIT.

  ## Parameters
    * `wit_path` - Path to the WIT file
    * `resource_name` - Name of the resource

  ## Returns
    * `{:ok, methods}` - List of method information
    * `{:error, reason}` - If resource not found or parsing failed
  """
  def get_resource_methods_from_wit(wit_path, resource_name) do
    case get_resource_from_wit(wit_path, resource_name) do
      {:ok, resource} -> {:ok, resource.methods}
      error -> error
    end
  end

  @doc """
  Checks if a resource exists in a WIT file.

  ## Parameters
    * `wit_path` - Path to the WIT file
    * `resource_name` - Name of the resource to check

  ## Returns
    * `true` if the resource exists
    * `false` otherwise
  """
  def resource_exists_in_wit?(wit_path, resource_name) do
    case get_resource_from_wit(wit_path, resource_name) do
      {:ok, _} -> true
      _ -> false
    end
  end

  @doc """
  Generates constructor and method call paths for a resource.

  This helper generates the correct paths to use with Instance.new_resource
  and Instance.call based on the WIT metadata.

  ## Parameters
    * `resource_info` - Resource information from `from_wit/1`
    * `opts` - Options:
      * `:package` - Package name (default: "component")

  ## Returns
    * Map with :constructor_path and :interface_path

  ## Example

      {:ok, resources} = Discovery.from_wit("counter.wit")
      resource = List.first(resources)
      paths = Discovery.generate_paths(resource)
      # => %{
      #      constructor_path: ["component:counter/types", "counter"],
      #      interface_path: ["component:counter/types"]
      #    }
  """
  def generate_paths(resource_info, opts \\ []) do
    package = Keyword.get(opts, :package, "component")

    interface_str = to_string(resource_info.interface)
    resource_str = to_string(resource_info.name)

    # Generate standard component model paths
    interface_path = ["#{package}:#{resource_str}/#{interface_str}"]
    constructor_path = interface_path ++ [resource_str]

    %{
      constructor_path: constructor_path,
      interface_path: interface_path
    }
  end
end
