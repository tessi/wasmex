defmodule Wasmex.Store do
  @moduledoc """
  A Store is a collection of WebAssembly instances and host-defined state.

  All WebAssembly instances and items will be attached to and refer to a Store.
  For example instances, functions, globals, and tables are all attached to a Store.
  Instances are created by instantiating a Module within a Store.

  A Store is intended to be a short-lived object in a program. No form of GC is
  implemented at this time so once an instance is created within a Store it will
  not be deallocated until the Store itself is garbage collected. This makes Store
  unsuitable for creating an unbounded number of instances in it because Store will
  never release this memory. It’s recommended to have a Store correspond roughly
  to the lifetime of a “main instance”.
  """

  alias Wasmex.StoreOrCaller
  alias Wasmex.Wasi.WasiOptions

  @doc """
  Creates a new WASM store.
  """
  @spec new() :: {:error, reason :: binary()} | {:ok, StoreOrCaller.t()}
  def new() do
    case Wasmex.Native.store_new() do
      {:ok, resource} -> {:ok, StoreOrCaller.wrap_resource(resource)}
      {:error, err} -> {:error, err}
    end
  end

  @doc """
  Creates a new WASM store with WASI support.

  See `Wasmex.Wasi.WasiOptions` for WASI configuration options.
  """
  @spec new_wasi(WasiOptions.t()) :: {:error, reason :: binary()} | {:ok, StoreOrCaller.t()}
  def new_wasi(%WasiOptions{} = options) do
    case Wasmex.Native.store_new_wasi(options) do
      {:ok, resource} -> {:ok, StoreOrCaller.wrap_resource(resource)}
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
