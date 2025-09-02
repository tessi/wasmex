defmodule Wasmex.Components.ResourceServer do
  @moduledoc """
  GenServer that runs individual host-defined resources as processes.

  ## Basic Usage

      # Start a resource
      {:ok, pid} = ResourceServer.start_link(MyApp.CounterResource, 0)

      # Call methods on the resource
      {:ok, result} = ResourceServer.call_method(pid, "increment", [])

      # Resource automatically cleans up when process terminates
      ResourceServer.stop(pid)  # or let supervision tree handle it

  ## Supervision Integration

  ResourceServer works seamlessly with OTP supervisors. Here are common patterns:

  ### Static Supervision

  Add resources to your application supervisor:

      defmodule MyApp.Application do
        use Application

        def start(_type, _args) do
          children = [
            # Your other application children...

            # Supervised resources with different restart strategies
            {ResourceServer, {CounterResource, 0}, restart: :permanent},
            {ResourceServer, {CacheResource, %{ttl: 3600}}, restart: :transient},
            {ResourceServer, {TempFileResource, "/tmp/upload"}, restart: :temporary}
          ]

          Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
        end
      end

  ### Dynamic Supervision

  Create resources on-demand using DynamicSupervisor:

      # In your application supervisor
      children = [
        {DynamicSupervisor, name: MyApp.ResourceSupervisor, strategy: :one_for_one}
      ]

      # Later, create resources dynamically
      DynamicSupervisor.start_child(
        MyApp.ResourceSupervisor,
        {ResourceServer, {MyResource, args}}
      )

  ### Custom Child Specs

  Customize how resources are supervised:

      Supervisor.child_spec(
        {ResourceServer, {MyResource, args}},
        id: :my_special_resource,
        restart: :transient,
        shutdown: 10_000
      )

  The resource's `terminate/2` callback is always called for cleanup, regardless
  of restart strategy.
  """

  use GenServer
  require Logger

  @doc """
  Starts a resource process.

  ## Parameters

  - `module` - The resource module implementing ResourceBehaviour
  - `args` - Arguments passed to the module's init callback
  - `opts` - GenServer options (name, timeout, etc.)

  ## Returns

  - `{:ok, pid}` - The process ID of the resource
  - `{:error, reason}` - If the resource failed to start
  """
  def start_link(module, args, opts \\ []) do
    GenServer.start_link(__MODULE__, {module, args}, opts)
  end

  @doc """
  Calls a method on the resource.

  ## Parameters

  - `pid` - The resource process ID
  - `method` - The method name as a string
  - `params` - List of parameters to pass to the method
  - `timeout` - Optional timeout (default 5000ms)

  ## Returns

  - `{:ok, result}` - The method result
  - `{:error, reason}` - If the method call failed
  """
  def call_method(pid, method, params, timeout \\ 5000) do
    GenServer.call(pid, {:method, method, params}, timeout)
  catch
    :exit, {:noproc, _} -> {:error, "Resource process no longer exists"}
    :exit, {:timeout, _} -> {:error, "Method call timed out"}
    :exit, reason -> {:error, {:process_exit, reason}}
  end

  @doc """
  Gets the type name of the resource.

  ## Parameters

  - `pid` - The resource process ID

  ## Returns

  - `{:ok, type_name}` - The resource type name
  - `{:error, reason}` - If the query failed
  """
  def get_type_name(pid) do
    GenServer.call(pid, :get_type_name)
  catch
    :exit, _ -> {:error, "Resource process no longer exists"}
  end

  @doc """
  Stops the resource process gracefully.

  This triggers cleanup via the terminate callback.

  ## Parameters

  - `pid` - The resource process ID
  - `reason` - The stop reason (default :normal)
  - `timeout` - Timeout for graceful shutdown (default :infinity)

  ## Returns

  - `:ok` - Resource stopped successfully
  """
  def stop(pid, reason \\ :normal, timeout \\ :infinity) do
    GenServer.stop(pid, reason, timeout)
  catch
    # Already stopped
    :exit, {:noproc, _} -> :ok
  end

  # Server callbacks

  @impl true
  def init({module, args}) do
    # Validate the module implements the behaviour by checking if it's in the behaviours list
    behaviours = module.module_info(:attributes)[:behaviour] || []

    if Wasmex.Components.ResourceBehaviour in behaviours do
      # Store the type name for quick access
      type_name = module.type_name()

      # Initialize the resource
      case module.init(args) do
        {:ok, state} ->
          # Set process metadata for better debugging
          Process.put(:resource_module, module)
          Process.put(:resource_type, type_name)

          Logger.debug("Started resource process #{inspect(self())} of type #{type_name}")

          {:ok, %{module: module, state: state, type_name: type_name}}

        {:error, reason} ->
          {:stop, {:error, reason}}
      end
    else
      {:stop, {:error, "Module #{module} does not implement ResourceBehaviour"}}
    end
  end

  @impl true
  def handle_call(
        {:method, method, params},
        _from,
        %{module: module, state: state} = server_state
      ) do
    # Dispatch the method to the resource module
    case module.handle_method(method, params, state) do
      {:reply, result, new_state} ->
        {:reply, {:ok, result}, %{server_state | state: new_state}}

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, %{server_state | state: new_state}}

      {:noreply, new_state} ->
        {:reply, {:ok, nil}, %{server_state | state: new_state}}

      invalid ->
        Logger.error("Invalid return from #{module}.handle_method/3: #{inspect(invalid)}")
        {:reply, {:error, "Invalid method handler return"}, server_state}
    end
  end

  @impl true
  def handle_call(:get_type_name, _from, %{type_name: type_name} = state) do
    {:reply, {:ok, type_name}, state}
  end

  @impl true
  def terminate(reason, %{module: module, state: state, type_name: type_name}) do
    Logger.debug(
      "Terminating resource process #{inspect(self())} of type #{type_name}, reason: #{inspect(reason)}"
    )

    # Call the module's terminate callback if it exists
    if function_exported?(module, :terminate, 2) do
      try do
        module.terminate(reason, state)
      rescue
        error ->
          Logger.error("Error in #{module}.terminate/2: #{inspect(error)}")
          :ok
      end
    else
      :ok
    end
  end

  # Fallback for invalid state (shouldn't happen)
  @impl true
  def terminate(_reason, _state) do
    :ok
  end
end
