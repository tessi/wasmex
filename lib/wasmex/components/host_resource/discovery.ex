defmodule Wasmex.Components.HostResource.Discovery do
  @moduledoc """
  Discovers host-owned resources imported by a WIT world.

  Use `from_wit/2` for a self-contained WIT source string. Use `from_path/2`
  for a WIT file or directory; directories can contain a `deps` subdirectory
  with dependency packages.

  Both functions accept `:world` when a package defines multiple worlds.
  `from_wit/2` also accepts `:path` for parser diagnostics. The corresponding
  resource lookup functions accept `:interface` to disambiguate resources
  with the same name.
  """

  @type function_kind :: :constructor | :method | :async_method | :static | :async_static

  @type function_info :: %{
          wit_name: String.t(),
          canonical_name: String.t(),
          elixir_name: String.t(),
          kind: function_kind(),
          arity: non_neg_integer(),
          has_return: boolean()
        }

  @type resource_info :: %{
          name: String.t(),
          interface: String.t(),
          interface_path: [String.t()],
          functions: [function_info()]
        }

  @spec from_wit(String.t(), keyword()) :: {:ok, [resource_info()]} | {:error, String.t()}
  @doc """
  Discovers imported resources from self-contained WIT source text.

  The `:path` option labels parser diagnostics and defaults to `"wit"`.
  """
  def from_wit(wit, options \\ []) when is_binary(wit) do
    path = Keyword.get(options, :path, "wit")
    world = Keyword.get(options, :world)

    normalize_result(Wasmex.Native.wit_imported_resources(path, wit, world))
  end

  @doc """
  Discovers imported resources from a WIT file or directory.

  When `path` is a directory, its `deps` subdirectory is resolved using the
  standard WIT package layout.
  """
  @spec from_path(Path.t(), keyword()) :: {:ok, [resource_info()]} | {:error, String.t()}
  def from_path(path, options \\ []) when is_binary(path) do
    world = Keyword.get(options, :world)
    normalize_result(Wasmex.Native.wit_imported_resources_from_path(path, world))
  end

  @spec get_resource_from_wit(String.t(), String.t() | atom(), keyword()) ::
          {:ok, resource_info()} | {:error, :not_found | String.t()}
  @doc """
  Finds one imported resource in self-contained WIT source text.
  """
  def get_resource_from_wit(wit, resource_name, options \\ [])
      when is_binary(wit) and (is_binary(resource_name) or is_atom(resource_name)) do
    with {:ok, resources} <- from_wit(wit, options) do
      find_resource(resources, resource_name, Keyword.get(options, :interface))
    end
  end

  @doc """
  Finds one imported resource in a WIT file or directory.
  """
  @spec get_resource_from_path(Path.t(), String.t() | atom(), keyword()) ::
          {:ok, resource_info()} | {:error, :not_found | String.t()}
  def get_resource_from_path(path, resource_name, options \\ [])
      when is_binary(path) and (is_binary(resource_name) or is_atom(resource_name)) do
    with {:ok, resources} <- from_path(path, options) do
      find_resource(resources, resource_name, Keyword.get(options, :interface))
    end
  end

  defp normalize_result({:error, reason}), do: {:error, reason}

  defp normalize_result(resources) when is_list(resources),
    do: {:ok, Enum.map(resources, &normalize_resource/1)}

  defp find_resource(resources, resource_name, interface) do
    resource_name = to_string(resource_name)

    matches =
      Enum.filter(resources, fn resource ->
        resource.name == resource_name and
          (is_nil(interface) or
             resource.interface == to_string(interface) or
             hd(resource.interface_path) == to_string(interface))
      end)

    case matches do
      [] ->
        {:error, :not_found}

      [resource] ->
        {:ok, resource}

      _ ->
        {:error,
         "Multiple imported resources are named `#{resource_name}`; pass the :interface option"}
    end
  end

  defp normalize_resource({name, interface, interface_path, functions}) do
    %{
      name: name,
      interface: interface,
      interface_path: [interface_path],
      functions: Enum.map(functions, &normalize_function/1)
    }
  end

  defp normalize_function({name, canonical_name, kind, arity, has_return}) do
    %{
      wit_name: name,
      canonical_name: canonical_name,
      elixir_name: String.replace(name, "-", "_"),
      kind: normalize_kind(kind),
      arity: arity,
      has_return: has_return
    }
  end

  defp normalize_kind("constructor"), do: :constructor
  defp normalize_kind("method"), do: :method
  defp normalize_kind("async-method"), do: :async_method
  defp normalize_kind("static"), do: :static
  defp normalize_kind("async-static"), do: :async_static
end
