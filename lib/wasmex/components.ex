defmodule Wasmex.Components do
  @moduledoc """
  This is the entry point to support for the [WebAssembly Component Model](https://component-model.bytecodealliance.org/).

  Support should be considered experimental at this point, with not all types yet supported.
  """

  use GenServer
  alias Wasmex.Wasi.WasiP2Options

  def start_link(%{bytes: component_bytes, wasi: %WasiP2Options{} = wasi_options}) do
    with {:ok, store} <- Wasmex.Components.Store.new_wasi(wasi_options),
         {:ok, component} <- Wasmex.Components.Component.new(store, component_bytes) do
      GenServer.start_link(__MODULE__, %{store: store, component: component})
    end
  end

  def start_link(%{bytes: component_bytes}) do
    with {:ok, store} <- Wasmex.Components.Store.new(),
         {:ok, component} <- Wasmex.Components.Component.new(store, component_bytes) do
      GenServer.start_link(__MODULE__, %{store: store, component: component})
    end
  end

  def start_link(opts) when is_list(opts) do
    with {:ok, store} <- build_store(opts),
         component_bytes <- Keyword.get(opts, :bytes),
         imports <- Keyword.get(opts, :imports, %{}),
         {:ok, component} <- Wasmex.Components.Component.new(store, component_bytes) do
      GenServer.start_link(
        __MODULE__,
        %{store: store, component: component, imports: imports},
        opts
      )
    end
  end

  defp build_store(opts) do
    if wasi_options = Keyword.get(opts, :wasi) do
      Wasmex.Components.Store.new_wasi(wasi_options)
    else
      Wasmex.Components.Store.new()
    end
  end

  @spec call_function(pid(), String.t() | atom(), list(number()), pos_integer()) ::
          {:ok, list(number())} | {:error, any()}
  def call_function(pid, name, params, timeout \\ 5000) do
    GenServer.call(pid, {:call_function, stringify(name), params}, timeout)
  end

  @impl true
  def init(%{store: store, component: component, imports: imports} = state) do
    case Wasmex.Components.Instance.new(store, component, imports) do
      {:ok, instance} ->
        {:ok, Map.merge(state, %{instance: instance, component: component, imports: imports})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def handle_call(
        {:call_function, name, params},
        from,
        %{instance: instance} = state
      ) do
    :ok = Wasmex.Components.Instance.call_function(instance, name, params, from)
    {:noreply, state}
  end

  @impl true
  def handle_info({:returned_function_call, result, from}, state) do
    case result do
      {:raise, reason} -> raise(reason)
      valid_result -> GenServer.reply(from, valid_result)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:invoke_callback, name, token, params},
        %{imports: imports, instance: _instance, component: component} = state
      ) do
    {:fn, function} = Map.get(imports, name)
    result = apply(function, params)
    :ok = Wasmex.Native.component_receive_callback_result(component.resource, token, true, result)
    {:noreply, state}
  end

  defp stringify(s) when is_binary(s), do: s
  defp stringify(s) when is_atom(s), do: Atom.to_string(s)

  defp elixirify(wasm_identifier),
    do: String.replace(wasm_identifier, "-", "_") |> String.to_atom()
end
