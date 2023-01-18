defmodule Wasmex.StoreOrCaller do
  @moduledoc ~S"""
  Either a `Wasmex.Store` or "Caller" for imported functions.

  A Store is a collection of Wasm instances and host-defined state, see `Wasmex.Store`.
  A Caller takes the place of a Store in imported function calls. If a Store is needed in
  Elixir-provided imported functions, always use the provided Caller because
  using the Store will cause a deadlock (the running Wasm instance locks the Stores Mutex).

  When configured, a StoreOrCaller can consume fuel to halt or yield execution as desired.
  See `Wasmex.EngineConfig.consume_fuel/2` for more information on fuel consumption.
  """

  @type t :: %__MODULE__{
          resource: binary(),
          reference: reference()
        }

  defstruct resource: nil,
            # The actual NIF store resource.
            # Normally the compiler will happily do stuff like inlining the
            # resource in attributes. This will convert the resource into an
            # empty binary with no warning. This will make that harder to
            # accidentally do.
            reference: nil

  def __wrap_resource__(resource) do
    %__MODULE__{
      resource: resource,
      reference: make_ref()
    }
  end

  @doc ~S"""
  Adds fuel to this Store for Wasm to consume while executing.

  For this method to work, fuel consumption must be enabled via
  `Wasmex.EngineConfig.consume_fuel/2. By default a `Wasmex.Store`
  starts with 0 fuel for Wasm to execute with (meaning it will
  immediately trap and halt execution). This function must be
  called for the store to have some fuel to allow WebAssembly
  to execute.

  Most Wasm instructions consume 1 unit of fuel. Some
  instructions, such as `nop`, `drop`, `block`, and `loop`, consume 0
  units, as any execution cost associated with them involves other
  instructions which do consume fuel.

  Note that at this time when fuel is entirely consumed it will cause
  Wasm to trap.

  ## Errors

  This function will return an error if fuel consumption is not enabled
  via `Wasmex.EngineConfig.consume_fuel/2`.

  ## Examples

      iex> {:ok, engine} = Wasmex.Engine.new(%Wasmex.EngineConfig{consume_fuel: true})
      iex> {:ok, store} = Wasmex.Store.new(nil, engine)
      iex> Wasmex.StoreOrCaller.add_fuel(store, 10)
      :ok
  """
  @spec add_fuel(__MODULE__.t(), pos_integer()) :: :ok | {:error, binary()}
  def add_fuel(%__MODULE__{resource: resource}, fuel) do
    case Wasmex.Native.store_or_caller_add_fuel(resource, fuel) do
      {} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc ~S"""
  Synthetically consumes fuel from this Store.

  For this method to work fuel, consumption must be enabled via
  `Wasmex.EngineConfig.consume_fuel/2`.

  WebAssembly execution will automatically consume fuel but if so desired
  the embedder can also consume fuel manually to account for relative
  costs of host functions, for example.

  This function will attempt to consume `fuel` units of fuel from within
  this store. If the remaining amount of fuel allows this then `{:ok, N}`
  is returned where `N` is the amount of remaining fuel. Otherwise an
  error is returned and no fuel is consumed.

  ## Errors

  This function will return an error either if fuel consumption is not
  enabled via `Wasmex.EngineConfig.consume_fuel/2` or if `fuel` exceeds
  the amount of remaining fuel within this store.

  ## Examples

      iex> {:ok, engine} = Wasmex.Engine.new(%Wasmex.EngineConfig{consume_fuel: true})
      iex> {:ok, store} = Wasmex.Store.new(nil, engine)
      iex> Wasmex.StoreOrCaller.add_fuel(store, 10)
      iex> Wasmex.StoreOrCaller.fuel_remaining(store)
      {:ok, 10}
  """
  @spec consume_fuel(__MODULE__.t(), pos_integer() | 0) ::
          {:ok, pos_integer()} | {:error, binary()}
  def consume_fuel(%__MODULE__{resource: resource}, fuel) do
    case Wasmex.Native.store_or_caller_consume_fuel(resource, fuel) do
      {:error, reason} -> {:error, reason}
      fuel_remaining -> {:ok, fuel_remaining}
    end
  end

  @doc ~S"""
  Returns the amount of fuel available for future execution of this store.

  ## Examples

      iex> {:ok, engine} = Wasmex.Engine.new(%Wasmex.EngineConfig{consume_fuel: true})
      iex> {:ok, store} = Wasmex.Store.new(nil, engine)
      iex> Wasmex.StoreOrCaller.add_fuel(store, 10)
      iex> Wasmex.StoreOrCaller.fuel_remaining(store)
      {:ok, 10}
  """
  @spec fuel_remaining(__MODULE__.t()) :: {:ok, pos_integer()} | {:error, binary()}
  def fuel_remaining(%__MODULE__{} = store_or_caller) do
    consume_fuel(store_or_caller, 0)
  end

  @doc ~S"""
  Returns the amount of fuel consumed by this store's execution so far.

  Note that fuel, if enabled, must be initially added via
  `Wasmex.StoreOrCaller.add_fuel/2`.

  ## Errors

  If fuel consumption is not enabled via
  `Wasmex.EngineConfig.consume_fuel/2` then this function will return
  an error tuple.

  ## Examples

      iex> {:ok, engine} = Wasmex.Engine.new(%Wasmex.EngineConfig{consume_fuel: true})
      iex> {:ok, store} = Wasmex.Store.new(nil, engine)
      iex> Wasmex.StoreOrCaller.fuel_consumed(store)
      {:ok, 0}
      iex> Wasmex.StoreOrCaller.add_fuel(store, 10)
      iex> {:ok, _fuel} = Wasmex.StoreOrCaller.consume_fuel(store, 8)
      iex> Wasmex.StoreOrCaller.fuel_consumed(store)
      {:ok, 8}
  """
  @spec fuel_consumed(__MODULE__.t()) :: {:ok, pos_integer()} | {:error, binary()}
  def fuel_consumed(%__MODULE__{resource: resource}) do
    case Wasmex.Native.store_or_caller_fuel_consumed(resource) do
      {:error, reason} -> {:error, reason}
      nil -> {:error, "Could not consume fuel: fuel is not configured in this store"}
      fuel_consumed -> {:ok, fuel_consumed}
    end
  end
end

defimpl Inspect, for: Wasmex.StoreOrCaller do
  import Inspect.Algebra

  def inspect(dict, opts) do
    concat(["#Wasmex.StoreOrCaller<", to_doc(dict.reference, opts), ">"])
  end
end
