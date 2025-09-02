defmodule Wasmex.Components.ResourceBehaviour do
  @moduledoc """
  Behaviour for implementing host-defined resources that run as processes.

  ## Quick Example

      defmodule MyCounter do
        @behaviour Wasmex.Components.ResourceBehaviour

        @impl true
        def type_name, do: "counter"

        @impl true
        def init(initial_value), do: {:ok, initial_value}

        @impl true
        def handle_method("increment", [], count), do: {:reply, count + 1, count + 1}
        def handle_method("get", [], count), do: {:reply, count, count}
        def handle_method(_, _, state), do: {:error, "unknown method", state}
      end

      # Usage
      {:ok, pid} = Wasmex.Components.ResourceServer.start_link(MyCounter, 0)
      {:ok, 1} = Wasmex.Components.ResourceServer.call_method(pid, "increment", [])
      {:ok, 1} = Wasmex.Components.ResourceServer.call_method(pid, "get", [])

  ## Full Example Implementation

      defmodule MyApp.CounterResource do
        @behaviour Wasmex.Components.ResourceBehaviour

        defstruct [:value, :increment_count]

        @impl true
        def type_name, do: "counter"

        @impl true
        def init(initial_value) when is_integer(initial_value) do
          {:ok, %__MODULE__{value: initial_value, increment_count: 0}}
        end

        def init(_) do
          {:error, "Counter requires an integer initial value"}
        end

        @impl true
        def handle_method("increment", [], state) do
          new_value = state.value + 1
          new_state = %{state | value: new_value, increment_count: state.increment_count + 1}
          {:reply, new_value, new_state}
        end

        @impl true
        def handle_method("get-value", [], state) do
          {:reply, state.value, state}
        end

        @impl true
        def handle_method("reset", [new_value], state) when is_integer(new_value) do
          {:reply, :ok, %{state | value: new_value}}
        end

        @impl true
        def handle_method("get-stats", [], state) do
          stats = %{
            current_value: state.value,
            total_increments: state.increment_count
          }
          {:reply, stats, state}
        end

        @impl true
        def handle_method(_method, _params, state) do
          {:error, "Unknown method", state}
        end

        @impl true
        def terminate(_reason, _state) do
          # Counters don't need cleanup
          :ok
        end
      end

  ## Process Lifecycle

  Resources are started as GenServer processes. When the process terminates
  (either normally or due to error), the `terminate/2` callback is called
  for cleanup.

  ## Supervision Patterns

  Resources integrate naturally with OTP supervision trees:

      # Simple supervision
      children = [
        {ResourceServer, {MyResource, "config"}}
      ]
      Supervisor.start_link(children, strategy: :one_for_one)

      # With restart configuration
      Supervisor.child_spec(
        {ResourceServer, {MyResource, args}},
        restart: :transient  # Only restart on crash
      )
  """

  @doc """
  Returns the WIT type name for this resource.

  This should be a valid WIT identifier (lowercase with hyphens).
  For example: "database-connection", "message-queue", "file-handle"
  """
  @callback type_name() :: String.t()

  @doc """
  Initializes the resource state.

  Called when a new resource process is started. This should perform
  any necessary setup like opening connections or allocating resources.

  ## Parameters

  - `args` - Arguments passed when creating the resource

  ## Return Values

  - `{:ok, state}` - Successful initialization with initial state
  - `{:error, reason}` - Initialization failed
  """
  @callback init(args :: any()) :: {:ok, any()} | {:error, any()}

  @doc """
  Handles a method call on the resource.

  This function is invoked when a WASM component calls a method on this resource.
  The method name and parameters are passed from the component.

  ## Parameters

  - `method` - The method name as a string
  - `params` - List of parameters from the WASM component
  - `state` - The current resource state

  ## Return Values

  - `{:reply, result, new_state}` - Success with result and updated state
  - `{:error, reason, new_state}` - Error with reason and updated state
  - `{:noreply, new_state}` - No return value, just state update

  The result value will be automatically converted to the appropriate WASM type.
  """
  @callback handle_method(method :: String.t(), params :: list(), state :: any()) ::
              {:reply, any(), any()} | {:error, any(), any()} | {:noreply, any()}

  @doc """
  Cleans up resources when the process terminates.

  This is called when the resource process is stopping. It should:

  - Close any open connections
  - Release any held resources
  - Perform final cleanup

  ## Parameters

  - `reason` - The reason for termination
  - `state` - The final resource state

  ## Return Values

  - `:ok` - Cleanup successful
  - `{:error, reason}` - Cleanup failed (logged but not propagated)
  """
  @callback terminate(reason :: term(), state :: any()) :: :ok | {:error, any()}

  @optional_callbacks terminate: 2
end
