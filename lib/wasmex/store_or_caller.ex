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
  Sets fuel to for Wasm to consume while executing.

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
      iex> Wasmex.StoreOrCaller.set_fuel(store, 10)
      :ok
  """
  @spec set_fuel(__MODULE__.t(), pos_integer()) :: :ok | {:error, binary()}
  def set_fuel(%__MODULE__{resource: resource}, fuel) do
    case Wasmex.Native.store_or_caller_set_fuel(resource, fuel) do
      {} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc ~S"""
  Returns the amount of fuel available for future execution of this store.

  ## Examples

      iex> {:ok, engine} = Wasmex.Engine.new(%Wasmex.EngineConfig{consume_fuel: true})
      iex> {:ok, store} = Wasmex.Store.new(nil, engine)
      iex> Wasmex.StoreOrCaller.set_fuel(store, 10)
      iex> Wasmex.StoreOrCaller.get_fuel(store)
      {:ok, 10}
  """
  @spec get_fuel(__MODULE__.t()) :: {:ok, pos_integer()} | {:error, binary()}
  def get_fuel(%__MODULE__{resource: resource}) do
    case Wasmex.Native.store_or_caller_get_fuel(resource) do
      {:error, reason} -> {:error, reason}
      get_fuel -> {:ok, get_fuel}
    end
  end
end

defimpl Inspect, for: Wasmex.StoreOrCaller do
  import Inspect.Algebra

  def inspect(dict, opts) do
    concat(["#Wasmex.StoreOrCaller<", to_doc(dict.reference, opts), ">"])
  end
end
