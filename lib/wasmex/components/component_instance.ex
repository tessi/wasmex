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

  # Private helper used by new_resource
  defp resource_new_internal(
         %__MODULE__{store_resource: store_resource, instance_resource: instance_resource},
         resource_type_path,
         params,
         from
       ) do
    path =
      cond do
        is_list(resource_type_path) ->
          Enum.map(resource_type_path, &Wasmex.Utils.stringify/1)

        is_atom(resource_type_path) ->
          [Wasmex.Utils.stringify(resource_type_path)]

        is_binary(resource_type_path) ->
          [resource_type_path]

        is_tuple(resource_type_path) ->
          resource_type_path |> Tuple.to_list() |> Enum.map(&Wasmex.Utils.stringify/1)

        true ->
          raise "Invalid resource type path - needs to be a list, binary, atom, or tuple"
      end

    Wasmex.Native.resource_new(store_resource, instance_resource, path, params, from)
  end

  @doc """
  Creates a new resource instance.

  This follows the same pattern as `Instance.new/3` and creates resources
  synchronously, handling the message passing internally.

  ## Parameters

    * `instance` - The component instance containing the resource type
    * `resource_type_path` - Path to the resource type, e.g., `["component:counter/types", "counter"]`
    * `params` - Constructor parameters as defined in the WIT interface
    * `timeout` - Timeout in milliseconds (default: 5000)

  ## Returns

    * `{:ok, resource}` - The created resource reference
    * `{:error, reason}` - If creation failed

  ## Examples

      # Create a counter resource with initial value 42
      {:ok, counter} = Wasmex.Components.Instance.new_resource(
        instance,
        ["component:counter/types", "counter"],
        [42]
      )
  """
  def new_resource(
        %__MODULE__{} = instance,
        resource_type_path,
        params,
        timeout \\ 5000
      ) do
    ref = make_ref()
    from = {self(), ref}

    :ok = resource_new_internal(instance, resource_type_path, params, from)

    receive do
      {:returned_function_call, result, ^from} -> result
    after
      timeout -> {:error, :timeout}
    end
  end

  @doc """
  Calls a method on a resource.

  This provides a clean API for calling resource methods, similar to
  `GenServer.call/3` but for WASM component resources.

  ## Parameters

    * `instance` - The component instance
    * `resource` - The resource reference
    * `method_name` - Name of the method to call
    * `params` - Method parameters (default: [])
    * `opts` - Options keyword list:
      * `:interface` - Interface path (default: ["component:counter/types"])
      * `:timeout` - Timeout in milliseconds (default: 5000)

  ## Returns

    * `{:ok, result}` - The method result
    * `{:error, reason}` - If the call failed

  ## Examples

      # Simple method call
      {:ok, value} = Wasmex.Components.Instance.call(instance, counter, "get-value")
      
      # Call with parameters
      :ok = Wasmex.Components.Instance.call(instance, counter, "reset", [100])
      
      # With explicit interface
      {:ok, result} = Wasmex.Components.Instance.call(
        instance,
        resource,
        "process",
        [42, "hello"],
        interface: ["my:interface"]
      )
  """
  def call(
        %__MODULE__{store_resource: store_resource, instance_resource: instance_resource},
        resource,
        method_name,
        params \\ [],
        opts \\ []
      ) do
    interface_path = Keyword.get(opts, :interface, ["component:counter/types"])
    timeout = Keyword.get(opts, :timeout, 5000)
    ref = make_ref()
    from = {self(), ref}

    path = Enum.map(interface_path, &Wasmex.Utils.stringify/1)

    :ok =
      Wasmex.Native.resource_call_method(
        store_resource,
        instance_resource,
        resource,
        path,
        method_name,
        params,
        from
      )

    receive do
      {:returned_function_call, result, ^from} -> result
    after
      timeout -> {:error, :timeout}
    end
  end
end
