defmodule Wasmex.Components.GuestResource.Discovery do
  @moduledoc """
  Discovery and introspection of guest resources from WIT files.

  This module provides tools to discover what resources a component exports
  and what functions those resources provide by parsing WIT files.
  """

  @doc """
  Extracts resource information from a WIT file.

  ## Parameters
    * `wit` - WebAssembly Interface Type content (e.g. read from a WIT file)
    * `options` - Keyword list of options
      * `:path` - Path to the WIT file (default: ".") - used for error messages only, the path is not used to read the file system

  ## Returns
    * `{:ok, resources}` - List of resources with their metadata
    * `{:error, reason}` - If parsing failed

  ## Example

      {:ok, resources} = Discovery.from_wit("...")
      # => [
      #      %{
      #        name: :counter,
      #        interface: :types,
      #        functions: [
      #          {:increment, 1, true},
      #          {:get_value, 1, true},
      #          {:reset, 2, false}
      #        ]
      #      }
      #    ]
  """
  def from_wit(wit, options \\ []) when is_binary(wit) do
    path = Keyword.get(options, :path, ".")
    resources = Wasmex.Native.wit_exported_resources(path, wit)

    case resources do
      {:error, reason} ->
        {:error, reason}

      _ ->
        parsed_resources =
          resources
          |> Enum.map(fn {name, interface, functions} ->
            functions =
              Enum.map(functions, fn {name, arity, has_return} ->
                %{
                  wit_name: name,
                  elixir_name: Wasmex.Components.FieldConverter.identifier_wit_to_elixir(name),
                  arity: arity,
                  has_return: has_return
                }
              end)

            %{
              name: name,
              interface: interface,
              functions: functions
            }
          end)

        {:ok, parsed_resources}
    end
  end

  @doc """
  Gets detailed information about a specific resource from WIT.

  ## Parameters
    * `wit` - WebAssembly Interface Type content (e.g. read from a WIT file)
    * `resource_name` - Name of the resource (as atom or string)
    * `options` - Keyword list of options
      * `:path` - Path to the WIT file (default: ".") - used for error messages only, the path is not used to read the file system

  ## Returns
    * `{:ok, resource_info}` - Resource information if found
    * `{:error, :not_found}` - If resource not found
    * `{:error, reason}` - Any other reason, for example if WIT parsing failed
  """
  def get_resource_from_wit(wit, resource_name, options \\ []) when is_binary(wit) do
    path = Keyword.get(options, :path, "wit")

    resource_atom =
      case resource_name do
        name when is_atom(name) -> name
        name when is_binary(name) -> String.to_atom(name)
      end

    case from_wit(wit, path: path) do
      {:ok, resources} ->
        case Enum.find(resources, &(&1.name == resource_atom)) do
          nil -> {:error, :not_found}
          resource -> {:ok, resource}
        end

      error ->
        error
    end
  end
end
