defmodule Wasmex.Components.ResourceManager do
  @moduledoc """
  Manages host resources and their interaction with WASM components.

  This module provides the bridge between Elixir resources
  (using ResourceBehaviour and ResourceServer) and WASM components.

  ## Usage

      # Define a resource module that implements ResourceBehaviour
      defmodule MyApp.CounterResource do
        @behaviour Wasmex.Components.ResourceBehaviour
        # ... implementation
      end

      # Create a resource
      {:ok, handle} = ResourceManager.create_resource(
        store,
        MyApp.CounterResource,
        42  # initial value
      )

      # Pass the handle to a WASM function
      Wasmex.Components.Instance.call_function(instance, "process-counter", [handle], from)

      # Resource automatically cleans up when its process terminates
  """

  use GenServer
  require Logger

  @type resource_id :: pos_integer()
  @type resource_handle :: reference()

  defmodule State do
    @moduledoc false
    defstruct [
      # Map of resource_id -> {pid, store_id}
      :resources,
      # Next available resource ID
      :next_id,
      # Map of store_id -> MapSet of resource_ids
      :store_resources,
      # Map of monitor_ref -> resource_id
      :monitors
    ]
  end

  # Client API

  @doc """
  Starts the process resource manager.

  This is typically started as part of the application supervision tree.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Creates a new process-based resource that can be passed to WASM components.

  ## Parameters

  - `store` - The component store
  - `module` - The resource module implementing ResourceBehaviour
  - `args` - Arguments passed to the module's init callback
  - `opts` - Optional GenServer options for the resource process

  ## Returns

  - `{:ok, handle}` - A resource handle that can be passed to WASM
  - `{:error, reason}` - If resource creation fails
  """
  def create_resource(store, module, args, opts \\ []) do
    GenServer.call(__MODULE__, {:create_resource, store, module, args, opts})
  end

  @doc """
  Calls a method on a process-based resource.

  This is invoked by the Rust NIF when a WASM component calls a method
  on a host-defined resource.

  ## Parameters

  - `resource_id` - The unique ID of the resource
  - `method` - The method name
  - `params` - List of parameters

  ## Returns

  - `{:ok, result}` - Success with result
  - `{:error, reason}` - If method call fails
  """
  def call_method(resource_id, method, params) do
    GenServer.call(__MODULE__, {:call_method, resource_id, method, params})
  end

  @doc """
  Explicitly stops a resource process.

  Note: This is optional as resources automatically clean up when their
  process terminates or when the store is destroyed.

  ## Parameters

  - `resource_id` - The unique ID of the resource

  ## Returns

  - `:ok` - Resource stopped successfully
  - `{:error, reason}` - If stop fails
  """
  def stop_resource(resource_id) do
    GenServer.call(__MODULE__, {:stop_resource, resource_id})
  end

  @doc """
  Stops all resources associated with a store.

  This is called when a store is being destroyed to ensure all
  resource processes are properly terminated.

  ## Parameters

  - `store_id` - The store ID

  ## Returns

  - `:ok` - All resources stopped
  """
  def stop_store_resources(store_id) do
    GenServer.call(__MODULE__, {:stop_store_resources, store_id})
  end

  @doc """
  Gets information about active resources.

  Useful for debugging and monitoring.

  ## Returns

  Map with resource statistics and details.
  """
  def get_resource_info do
    GenServer.call(__MODULE__, :get_resource_info)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    state = %State{
      resources: %{},
      next_id: 1,
      store_resources: %{},
      monitors: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:create_resource, store, module, args, opts}, _from, state) do
    # Validate the module implements the behaviour
    behaviours = module.module_info(:attributes)[:behaviour] || []

    if Wasmex.Components.ResourceBehaviour in behaviours do
      # Get the store ID
      store_id = get_store_id(store)

      # Start the resource process
      case Wasmex.Components.ResourceServer.start_link(module, args, opts) do
        {:ok, pid} ->
          handle_resource_process_started(pid, store, store_id, state)

        {:error, reason} ->
          {:reply, {:error, "Failed to start resource process: #{inspect(reason)}"}, state}
      end
    else
      {:reply, {:error, "Module does not implement ResourceBehaviour"}, state}
    end
  end

  @impl true
  def handle_call({:call_method, resource_id, method, params}, _from, state) do
    case Map.get(state.resources, resource_id) do
      {pid, _store_id} ->
        # Call the method on the resource process
        result = Wasmex.Components.ResourceServer.call_method(pid, method, params)

        Logger.debug("Called method #{method} on resource #{resource_id}: #{inspect(result)}")

        {:reply, result, state}

      nil ->
        {:reply, {:error, "Resource not found: #{resource_id}"}, state}
    end
  end

  @impl true
  def handle_call({:stop_resource, resource_id}, _from, state) do
    case Map.get(state.resources, resource_id) do
      {pid, _store_id} ->
        # Stop the resource process (this will trigger handle_info with DOWN)
        Wasmex.Components.ResourceServer.stop(pid)
        {:reply, :ok, state}

      nil ->
        # Resource already stopped or doesn't exist
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:stop_store_resources, store_id}, _from, state) do
    # Get all resources for this store
    resource_ids = Map.get(state.store_resources, store_id, MapSet.new())

    # Stop each resource process
    Enum.each(resource_ids, fn resource_id ->
      case Map.get(state.resources, resource_id) do
        {pid, ^store_id} ->
          Wasmex.Components.ResourceServer.stop(pid)
          Logger.debug("Stopping resource #{resource_id} for store #{store_id}")

        _ ->
          :ok
      end
    end)

    # The actual cleanup will happen in handle_info when we receive DOWN messages
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:get_resource_info, _from, state) do
    info = %{
      active_resources: map_size(state.resources),
      next_id: state.next_id,
      stores_with_resources: map_size(state.store_resources),
      resources_by_store:
        Map.new(state.store_resources, fn {store_id, resource_ids} ->
          {store_id, MapSet.size(resource_ids)}
        end),
      resource_details:
        Map.new(state.resources, fn {resource_id, {pid, store_id}} ->
          {resource_id, %{pid: pid, store_id: store_id, alive: Process.alive?(pid)}}
        end)
    }

    {:reply, info, state}
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, pid, reason}, state) do
    # A resource process has terminated
    case Map.get(state.monitors, monitor_ref) do
      resource_id when is_integer(resource_id) ->
        Logger.debug(
          "Resource process #{resource_id} (pid: #{inspect(pid)}) terminated: #{inspect(reason)}"
        )

        # Clean up state
        {_pid, store_id} = Map.get(state.resources, resource_id, {nil, nil})

        resources = Map.delete(state.resources, resource_id)
        monitors = Map.delete(state.monitors, monitor_ref)

        store_resources =
          remove_from_store_resources(state.store_resources, store_id, resource_id)

        new_state = %State{
          state
          | resources: resources,
            monitors: monitors,
            store_resources: store_resources
        }

        {:noreply, new_state}

      nil ->
        # Unknown monitor, ignore
        {:noreply, state}
    end
  end

  # Helper functions

  defp get_store_id(store) do
    :erlang.phash2(store)
  end

  defp create_native_handle(store, resource_id, type_name) do
    # Call the NIF to create a native resource handle
    # This will need to be adjusted based on the actual NIF implementation
    try do
      case Wasmex.Native.host_resource_new(store, resource_id, type_name) do
        {:ok, handle} -> {:ok, handle}
        {:error, reason} -> {:error, reason}
        error -> {:error, error}
      end
    rescue
      e -> {:error, "NIF not yet implemented for process-based resources: #{inspect(e)}"}
    end
  end

  defp update_store_resources(store_resources, store_id, resource_id) do
    Map.update(store_resources, store_id, MapSet.new([resource_id]), fn set ->
      MapSet.put(set, resource_id)
    end)
  end

  defp remove_from_store_resources(store_resources, nil, _resource_id) do
    store_resources
  end

  defp remove_from_store_resources(store_resources, store_id, resource_id) do
    Map.update(store_resources, store_id, MapSet.new(), fn set ->
      MapSet.delete(set, resource_id)
    end)
  end

  defp handle_resource_process_started(pid, store, store_id, state) do
    # Get the type name
    {:ok, type_name} = Wasmex.Components.ResourceServer.get_type_name(pid)

    # Allocate a resource ID
    resource_id = state.next_id

    # Monitor the process for automatic cleanup
    monitor_ref = Process.monitor(pid)

    # Create the native resource handle via NIF
    case create_native_handle(store, resource_id, type_name) do
      {:ok, handle} ->
        # Update state
        resources = Map.put(state.resources, resource_id, {pid, store_id})

        store_resources =
          update_store_resources(state.store_resources, store_id, resource_id)

        monitors = Map.put(state.monitors, monitor_ref, resource_id)

        new_state = %State{
          state
          | resources: resources,
            next_id: resource_id + 1,
            store_resources: store_resources,
            monitors: monitors
        }

        Logger.debug(
          "Created process resource #{resource_id} (pid: #{inspect(pid)}) of type #{type_name} for store #{store_id}"
        )

        {:reply, {:ok, handle}, new_state}

      {:error, reason} ->
        # Stop the process if native handle creation failed
        Wasmex.Components.ResourceServer.stop(pid)
        {:reply, {:error, reason}, state}
    end
  end
end
