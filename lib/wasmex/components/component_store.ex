defmodule Wasmex.Components.Store do
  @moduledoc """
  This is the component model equivalent of `Wasmex.Store`
  """
  alias Wasmex.Wasi.WasiP2Options
  alias Wasmex.Engine

  defstruct resource: nil, reference: nil

  def __wrap_resource__(resource) do
    %__MODULE__{
      resource: resource,
      reference: make_ref()
    }
  end

  def new(store_limits \\ nil, engine \\ nil) do
    %Engine{resource: engine_resource} = engine || Engine.default()

    case Wasmex.Native.component_store_new(
           store_limits,
           engine_resource
         ) do
      {:error, err} -> {:error, err}
      resource -> {:ok, __MODULE__.__wrap_resource__(resource)}
    end
  end

  def new_wasi(%WasiP2Options{} = options \\ %WasiP2Options{}, store_limits \\ nil, engine \\ nil) do
    %Engine{resource: engine_resource} = engine || Engine.default()

    case Wasmex.Native.component_store_new_wasi(
           options,
           store_limits,
           engine_resource
         ) do
      {:error, err} -> {:error, err}
      resource -> {:ok, __MODULE__.__wrap_resource__(resource)}
    end
  end
end
