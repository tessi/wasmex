defmodule Wasmex.Components.Store do
  alias Wasmex.Wasi.WasiP2Options
  alias Wasmex.Engine

  defstruct resource: nil, reference: nil

  def __wrap_resource__(resource) do
    %__MODULE__{
      resource: resource,
      reference: make_ref()
    }
  end

  def new(options \\ nil, store_limits \\ nil, engine \\ nil)

  def new(nil, store_limits, engine) do
    %Engine{resource: engine_resource} = engine || Engine.default()

    case Wasmex.Native.component_store_new(
           store_limits,
           engine_resource
         ) do
      {:error, err} -> {:error, err}
      resource -> {:ok, __MODULE__.__wrap_resource__(resource)}
    end
  end

  def new(%WasiP2Options{} = options, store_limits, engine) do
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
