defmodule Wasmex.Components.Instance do
  @moduledoc """
  The component model equivalent to `Wasmex.Instance`
  """
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

    case Wasmex.Native.component_instance_new(
           store_or_caller_resource,
           component_resource,
           imports
         ) do
      {:error, err} -> {:error, err}
      resource -> {:ok, __wrap_resource__(store_or_caller_resource, resource)}
    end
  end

  def call_function(
        %__MODULE__{store_resource: store_resource, instance_resource: instance_resource},
        function_or_path,
        args,
        from
      ) do
    path =
      cond do
        is_list(function_or_path) ->
          Enum.map(function_or_path, &Wasmex.Utils.stringify/1)

        is_atom(function_or_path) ->
          [Wasmex.Utils.stringify(function_or_path)]

        is_binary(function_or_path) ->
          [function_or_path]

        is_tuple(function_or_path) ->
          function_or_path |> Tuple.to_list() |> Enum.map(&Wasmex.Utils.stringify/1)

        true ->
          raise "Invalid function or path - needs to be a list, binary, or tuple"
      end

    Wasmex.Native.component_call_function(store_resource, instance_resource, path, args, from)
  end
end
