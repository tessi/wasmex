defmodule Wasmex.Store do
  @moduledoc ~S"""
  A Store is a collection of WASM instances and host-defined state.

  All WASM instances and items will be attached to and refer to a Store.
  For example instances, functions, globals, and tables are all attached to a Store.
  Instances are created by instantiating a Module within a Store.
  Many functions of the Wasmex API require a Store in the form of a `Wasmex.StoreOrCaller`
  to be passed in.

  A Store is intended to be a short-lived object in a program. No form of GC is
  implemented at this time so once an instance is created within a Store it will
  not be deallocated until the Store itself is garbage collected. This makes Store
  unsuitable for creating an unbounded number of instances in it because Store will
  never release this memory. It’s recommended to have a Store correspond roughly
  to the lifetime of a “main instance”.
  """

  alias Wasmex.StoreOrCaller
  alias Wasmex.Wasi.WasiOptions

  @doc ~S"""
  Creates a new WASM store.

  Returns a `Wasmex.StoreOrCaller` even though we know it’s definitely a Store.
  This allows Elixir-provided imported functions, which only have a "Caller", to use the same Wasmex APIs.

  ## Examples

      iex> {:ok, %Wasmex.StoreOrCaller{}} = Wasmex.Store.new()
  """
  @spec new() :: {:error, reason :: binary()} | {:ok, StoreOrCaller.t()}
  def new() do
    case Wasmex.Native.store_new() do
      {:ok, resource} -> {:ok, StoreOrCaller.__wrap_resource__(resource)}
      {:error, err} -> {:error, err}
    end
  end

  @doc ~S"""
  Creates a new WASM store with WASI support.

  Returns a `Wasmex.StoreOrCaller` even though we know it’s definitely a Store.
  This allows Elixir-provided imported functions, which only have a "Caller", to use the same Wasmex APIs.

  See `Wasmex.Wasi.WasiOptions` for WASI configuration options.

  ## Examples

      iex> {:ok, %Wasmex.StoreOrCaller{}} = Wasmex.Store.new_wasi(%Wasmex.Wasi.WasiOptions{})
  """
  @spec new_wasi(WasiOptions.t()) :: {:error, reason :: binary()} | {:ok, StoreOrCaller.t()}
  def new_wasi(%WasiOptions{} = options) do
    case Wasmex.Native.store_new_wasi(options) do
      {:ok, resource} -> {:ok, StoreOrCaller.__wrap_resource__(resource)}
      {:error, err} -> {:error, err}
    end
  end
end

defimpl Inspect, for: Wasmex.Store do
  import Inspect.Algebra

  def inspect(dict, opts) do
    concat(["#Wasmex.Store<", to_doc(dict.reference, opts), ">"])
  end
end
