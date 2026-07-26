defmodule Wasmex.Components.Instance do
  @moduledoc """
  The component model equivalent to `Wasmex.Instance`.

  Most applications should use `Wasmex.Components` or
  `Wasmex.Components.ComponentServer` instead.
  """
  @type t :: %__MODULE__{
          store_resource: binary(),
          instance_resource: binary(),
          reference: reference()
        }

  defstruct store_resource: nil,
            instance_resource: nil,
            # The actual NIF store resource.
            # Normally the compiler will happily do stuff like inlining the
            # resource in attributes. This will convert the resource into an
            # empty binary with no warning. This will make that harder to
            # accidentally do.
            reference: nil

  def __wrap_resource__(store_resource, instance_resource) do
    %__MODULE__{
      store_resource: store_resource,
      instance_resource: instance_resource,
      reference: make_ref()
    }
  end

  def new(store_or_caller, component, imports) do
    %{resource: store_or_caller_resource} = store_or_caller
    %{resource: component_resource} = component

    result =
      Wasmex.Utils.native_request(fn from ->
        Wasmex.Native.component_instance_new(
          store_or_caller_resource,
          component_resource,
          imports,
          from
        )
      end)

    case result do
      {:error, err} -> {:error, err}
      resource -> {:ok, __wrap_resource__(store_or_caller_resource, resource)}
    end
  end

  @doc """
  Schedules a call to an exported component function.

  The `from` argument must be the caller tuple passed to
  `c:GenServer.handle_call/3`. The result is sent to that caller after execution.
  If `timeout` expires first, the component call continues to completion because
  Wasmtime cannot cancel it without invalidating the instance; the late result
  is discarded.
  """
  @spec call_function(
          __MODULE__.t(),
          Wasmex.Components.function_name_or_path(),
          list(),
          GenServer.from(),
          non_neg_integer() | nil
        ) :: :ok
  def call_function(
        %__MODULE__{store_resource: store_resource, instance_resource: instance_resource},
        function_or_path,
        args,
        from,
        timeout \\ nil
      ) do
    function_path = parse_function_path(function_or_path)

    Wasmex.Native.component_call_function(
      store_resource,
      instance_resource,
      function_path,
      args,
      from,
      timeout
    )
  end

  defp parse_function_path(path) when is_binary(path), do: [path]
  defp parse_function_path(path) when is_atom(path), do: [Atom.to_string(path)]

  defp parse_function_path(path) when is_list(path) do
    Enum.map(path, fn
      p when is_binary(p) -> p
      p when is_atom(p) -> Atom.to_string(p)
    end)
  end

  defp parse_function_path(path) when is_tuple(path) do
    path
    |> Tuple.to_list()
    |> parse_function_path()
  end
end
