defmodule Wasmex.Components do
  use GenServer

  def start_link(%{bytes: component_bytes}) do
    with {:ok, store} <- Wasmex.Components.Store.new(%Wasmex.Wasi.WasiP2Options{}),
         {:ok, component} <- Wasmex.Components.Component.new(store, component_bytes) do
      GenServer.start_link(__MODULE__, %{store: store, component: component})
    end
  end

  @spec call_function(pid(), String.t() | atom(), list(number()), pos_integer()) ::
          {:ok, list(number())} | {:error, any()}
  def call_function(pid, name, params, timeout \\ 5000) do
    GenServer.call(pid, {:call_function, stringify(name), params}, timeout)
  end

  @impl true
  def init(%{store: store, component: component} = state) do
    case Wasmex.Components.Instance.new(store, component) do
      {:ok, instance} -> {:ok, Map.merge(state, %{instance: instance})}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def handle_call(
        {:call_function, name, params},
        _from,
        %{instance: instance} = state
      ) do
    case Wasmex.Components.Instance.call_function(instance, name, params) do
      {:ok, result} -> {:reply, {:ok, result}, state}
      {:error, error} -> {:error, error}
    end
  end

  defp stringify(s) when is_binary(s), do: s
  defp stringify(s) when is_atom(s), do: Atom.to_string(s)
end
