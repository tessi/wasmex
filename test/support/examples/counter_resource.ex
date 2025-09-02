defmodule Wasmex.Test.Support.Examples.CounterResource do
  @moduledoc """
  Example implementation of a counter resource.

  This demonstrates how to create a stateful resource that runs as a process,
  with automatic cleanup and no need for manual drop() calls.

  ## Key Features

  - Runs as a GenServer process
  - State is managed internally by the process
  - Returns idiomatic {:ok, value} | {:error, reason} tuples
  - Automatic cleanup on process termination
  - Can crash without affecting other resources

  ## Usage

      # Start the resource (usually done via ResourceManager)
      {:ok, pid} = ResourceServer.start_link(
        CounterResource, 
        %{initial_value: 10, name: "my-counter"}
      )
      
      # Call methods - all return {:ok, value} or {:error, reason}
      {:ok, {:ok, 11}} = ResourceServer.call_method(pid, "increment", [])
      {:ok, {:ok, 10}} = ResourceServer.call_method(pid, "decrement", [])
      {:ok, {:ok, 10}} = ResourceServer.call_method(pid, "get-value", [])
      
      # Process automatically cleans up on termination
  """

  @behaviour Wasmex.Components.ResourceBehaviour

  require Logger

  defmodule State do
    @moduledoc false
    defstruct value: 0, name: "default", operation_count: 0
  end

  # ResourceBehaviour callbacks

  @impl true
  def type_name, do: "counter"

  @impl true
  def init(args) when is_map(args) do
    initial_value = Map.get(args, :initial_value, 0)
    name = Map.get(args, :name, "default")

    Logger.debug("Initializing CounterResource: #{name} with value: #{initial_value}")

    {:ok, %State{value: initial_value, name: name, operation_count: 0}}
  end

  def init(initial_value) when is_integer(initial_value) do
    init(%{initial_value: initial_value})
  end

  def init(_args) do
    init(%{})
  end

  @impl true
  def handle_method("increment", [], state) do
    new_value = state.value + 1
    new_state = %State{state | value: new_value, operation_count: state.operation_count + 1}
    {:reply, {:ok, new_value}, new_state}
  end

  def handle_method("increment", [amount], state) when is_integer(amount) do
    new_value = state.value + amount
    new_state = %State{state | value: new_value, operation_count: state.operation_count + 1}
    {:reply, {:ok, new_value}, new_state}
  end

  def handle_method("decrement", [], state) do
    new_value = state.value - 1
    new_state = %State{state | value: new_value, operation_count: state.operation_count + 1}
    {:reply, {:ok, new_value}, new_state}
  end

  def handle_method("decrement", [amount], state) when is_integer(amount) do
    new_value = state.value - amount
    new_state = %State{state | value: new_value, operation_count: state.operation_count + 1}
    {:reply, {:ok, new_value}, new_state}
  end

  def handle_method("get-value", [], state) do
    {:reply, {:ok, state.value}, state}
  end

  def handle_method("reset", [], state) do
    new_state = %State{state | value: 0, operation_count: state.operation_count + 1}
    {:reply, {:ok, 0}, new_state}
  end

  def handle_method("get-name", [], state) do
    {:reply, {:ok, state.name}, state}
  end

  def handle_method("set-name", [new_name], state) when is_binary(new_name) do
    new_state = %State{state | name: new_name, operation_count: state.operation_count + 1}
    {:reply, :ok, new_state}
  end

  def handle_method("get-stats", [], state) do
    stats = %{
      value: state.value,
      name: state.name,
      operation_count: state.operation_count,
      process: self()
    }

    {:reply, {:ok, stats}, state}
  end

  def handle_method("crash", [], _state) do
    # Intentionally crash to demonstrate process isolation
    raise "Intentional crash for testing"
  end

  def handle_method(method, params, state) do
    Logger.warning("Unknown method: #{method} with params: #{inspect(params)}")
    {:error, "Unknown method: #{method}", state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.debug(
      "CounterResource terminating: #{state.name} " <>
        "with final value: #{state.value}, " <>
        "operations performed: #{state.operation_count}, " <>
        "reason: #{inspect(reason)}"
    )

    :ok
  end
end
