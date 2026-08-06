defmodule Wasmex.Components.GuestResource.Discovery do
  @moduledoc """
  Discovers guest-owned resources exported by a WIT world.

  The returned metadata includes the component's real interface export name,
  including its package namespace and version. It can therefore be used
  directly for dynamic Wasmtime export lookup without guessing a package path.
  """

  @type function_kind :: :constructor | :method | :async_method | :static | :async_static

  @type function_info :: %{
          wit_name: String.t(),
          elixir_name: String.t(),
          kind: function_kind(),
          arity: non_neg_integer(),
          has_return: boolean()
        }

  @type resource_info :: %{
          name: String.t(),
          interface: String.t(),
          interface_path: [String.t()],
          constructor_path: [String.t()],
          functions: [function_info()]
        }

  @doc """
  Returns metadata for all guest resources exported by the selected WIT world.

  `:path` is used in parser diagnostics and defaults to `"wit"`. Pass `:world`
  when the WIT contains more than one world.
  """
  @spec from_wit(String.t(), keyword()) :: {:ok, [resource_info()]} | {:error, String.t()}
  def from_wit(wit, options \\ []) when is_binary(wit) do
    path = Keyword.get(options, :path, "wit")
    world = Keyword.get(options, :world)

    case Wasmex.Native.wit_exported_resources(path, wit, world) do
      {:error, reason} ->
        {:error, reason}

      resources when is_list(resources) ->
        {:ok, Enum.map(resources, &normalize_resource/1)}
    end
  end

  @doc """
  Finds one exported guest resource by its WIT name.
  """
  @spec get_resource_from_wit(String.t(), String.t() | atom(), keyword()) ::
          {:ok, resource_info()} | {:error, :not_found | String.t()}
  def get_resource_from_wit(wit, resource_name, options \\ [])
      when is_binary(wit) and (is_binary(resource_name) or is_atom(resource_name)) do
    resource_name = to_string(resource_name)

    with {:ok, resources} <- from_wit(wit, options) do
      case Enum.find(resources, &(&1.name == resource_name)) do
        nil -> {:error, :not_found}
        resource -> {:ok, resource}
      end
    end
  end

  defp normalize_resource({name, interface, interface_export, functions}) do
    %{
      name: name,
      interface: interface,
      interface_path: [interface_export],
      constructor_path: [interface_export, name],
      functions: Enum.map(functions, &normalize_function/1)
    }
  end

  defp normalize_function({name, _canonical_name, kind, arity, has_return}) do
    %{
      wit_name: name,
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
