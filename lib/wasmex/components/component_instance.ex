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
    function_path = parse_function_path(function_or_path)

    Wasmex.Native.component_call_function(
      store_resource,
      instance_resource,
      function_path,
      args,
      from
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

  @doc """
  Creates a new guest resource instance.

  Guest resources are defined in the WIT interface of the component
  and can be called either from the component itself or from the host.

  ## Parameters

    * `instance` - The component instance containing the resource type
    * `resource_type_path` - Path to the resource type, e.g., `["component:counter/types", "counter"]`
    * `params` - Constructor parameters as defined in the WIT interface
    * `timeout` - Timeout in milliseconds (default: 5000)

  ## Returns

    * `{:ok, resource}` - The created resource reference
    * `{:error, reason}`

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

    :ok =
      Wasmex.Native.resource_new(
        instance.store_resource,
        instance.instance_resource,
        path,
        params,
        from
      )

    receive do
      {:returned_function_call, result, ^from} -> result
    after
      timeout -> {:error, :timeout}
    end
  end

  @doc """
  Calls a function on a resource.

  ## Parameters

    * `instance` - The component instance
    * `resource` - The resource reference
    * `function_name` - Name of the function to call
    * `params` - parameters (default: [])
    * `opts` - Options keyword list:
      * `:interface` - Interface path (default: ["component:counter/types"])
      * `:timeout` - Timeout in milliseconds (default: 5000)

  ## Returns

    * `{:ok, result}` - The function call result
    * `{:error, reason}`

  ## Examples

      # Call without parameters
      {:ok, value} = Wasmex.Components.Instance.call(instance, counter, "get-value")

      # Call with parameters
      :ok = Wasmex.Components.Instance.call(instance, counter, "reset", [100])

      # With explicit interface
      {:ok, result} = Wasmex.Components.Instance.call(
        instance,
        resource,
        "process",
        [42, "hello"],
        interface: ["component:counter/types"]
      )
  """
  def call(
        %__MODULE__{store_resource: store_resource, instance_resource: instance_resource},
        resource,
        function_name,
        params \\ [],
        opts \\ []
      ) do
    # TODO: this is not a usable default
    interface_path = Keyword.get(opts, :interface, ["component:counter/types"])
    timeout = Keyword.get(opts, :timeout, 5000)
    ref = make_ref()
    from = {self(), ref}

    path = Enum.map(interface_path, &Wasmex.Utils.stringify/1)

    :ok =
      Wasmex.Native.resource_call_function(
        store_resource,
        instance_resource,
        resource,
        path,
        function_name,
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
