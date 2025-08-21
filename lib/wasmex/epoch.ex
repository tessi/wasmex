defmodule Wasmex.Epoch do
  @moduledoc """
  Epoch-based interruption for WebAssembly execution.
  
  Epochs provide a performant way to interrupt long-running WebAssembly code
  without the overhead of fuel metering. The engine increments an internal
  epoch counter periodically, and execution is interrupted when the counter
  exceeds a store's deadline.
  
  ## Configuration
  
  Enable epoch interruption when creating an engine:
  
      engine_config = %{
        epoch_interruption: true,
        epoch_interval_ms: 10  # Increment epoch every 10ms
      }
      {:ok, engine} = Wasmex.Engine.new(engine_config)
  
  ## Usage
  
      # Set deadline as number of epoch ticks
      Wasmex.Epoch.set_deadline(store, 100)  # Interrupt after 100 ticks
      
      # Set deadline as timeout in milliseconds
      Wasmex.Epoch.set_timeout_ms(store, 1000)  # Interrupt after 1 second
  
  When the deadline is exceeded, the WebAssembly execution will trap with
  an epoch deadline exceeded error.
  """
  
  alias Wasmex.StoreOrCaller
  
  @doc """
  Sets the epoch deadline for a store as a number of epoch ticks.
  
  The execution will be interrupted when the engine's epoch counter
  exceeds this deadline.
  
  ## Examples
  
      iex> Wasmex.Epoch.set_deadline(store, 100)
      :ok
  """
  @spec set_deadline(StoreOrCaller.t(), non_neg_integer()) :: :ok | {:error, term()}
  def set_deadline(%StoreOrCaller{resource: resource}, ticks) when is_integer(ticks) and ticks >= 0 do
    case Wasmex.Native.store_set_epoch_deadline(resource, ticks) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
  
  @doc """
  Sets the epoch deadline for a store as a timeout in milliseconds.
  
  The deadline is calculated based on the current epoch and the specified
  timeout. The actual precision depends on the epoch interval configured
  for the engine (default 10ms).
  
  ## Examples
  
      iex> Wasmex.Epoch.set_timeout_ms(store, 1000)  # 1 second timeout
      :ok
  """
  @spec set_timeout_ms(StoreOrCaller.t(), non_neg_integer()) :: :ok | {:error, term()}
  def set_timeout_ms(%StoreOrCaller{resource: resource}, timeout_ms) when is_integer(timeout_ms) and timeout_ms >= 0 do
    case Wasmex.Native.store_set_epoch_timeout(resource, timeout_ms) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end