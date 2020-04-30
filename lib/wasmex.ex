defmodule Wasmex do
  @moduledoc """
  Wasmex is an Elixir library for executing WebAssembly binaries.

  WASM functions can be executed like this:

  ```elixir
  {:ok, bytes } = File.read("wasmex_test.wasm")
  {:ok, instance } = Wasmex.start_link.from_bytes(bytes)

  {:ok, [42]} == Wasmex.call_function(instance, "sum", [50, -8])
  ```

  Memory can be read/written using `Wasmex.Memory`:

  ```elixir
  offset = 7
  index = 4
  value = 42

  {:ok, memory} = Wasmex.Instance.memory(instance, :uint8, offset)
  Wasmex.Memory.set(memory, index, value)
  IO.puts Wasmex.Memory.get(memory, index) # 42
  ```
  """
  use GenServer

  # Client

  def start_link(%{bytes: bytes, imports: imports}) when is_binary(bytes) do
    GenServer.start_link(__MODULE__, %{bytes: bytes, imports: stringify_keys(imports)})
  end
  def start_link(bytes) when is_binary(bytes) do
    start_link(%{bytes: bytes, imports: %{}})
  end

  def function_exists(pid, name) do
    GenServer.call(pid, {:exported_function_exists, stringify(name)})
  end

  def call_function(pid, name, params) do
    GenServer.call(pid, {:call_function, stringify(name), params})
  end

  def memory(pid, size, offset) when size in [:uint8, :int8, :uint16, :int16, :uint32, :int32] do
    GenServer.call(pid, {:memory, size, offset})
  end

  def stringify_keys(atom_key_map) when is_map(atom_key_map) do
    for {key, val} <- atom_key_map, into: %{}, do: {stringify(key), stringify_keys(val)} end
  def stringify_keys(value), do: value

  defp stringify(s) when is_binary(s), do: s
  defp stringify(s) when is_atom(s), do: Atom.to_string(s)

  # Server

  @doc """
  Params:

  * bytes (binary): the WASM bites defining the WASM module
  * imports (map): a map defining imports. Structure is:
                   %{
                     "namespace_name": %{
                       "import_name": {[:uint8, :uint8],[:uint8], callback}
                     }
                   }
  """
  @impl true
  def init(%{bytes: bytes, imports: imports}) when is_binary(bytes) do
    {:ok, instance} = Wasmex.Instance.from_bytes(bytes, imports)
    {:ok, %{instance: instance, imports: imports}}
  end

  @impl true
  def handle_call({:memory, size, offset}, _from, %{instance: instance} = state)
      when size in [:uint8, :int8, :uint16, :int16, :uint32, :int32] do
    case Wasmex.Memory.from_instance(instance, size, offset) do
      {:ok, memory} -> {:reply, {:ok, memory}, state}
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  @impl true
  def handle_call({:exported_function_exists, name}, _from, %{instance: instance} = state)
      when is_binary(name) do
    {:reply, Wasmex.Instance.function_export_exists(instance, name), state}
  end

  @impl true
  def handle_call({:call_function, name, params}, from, %{instance: instance} = state) do
    :ok = Wasmex.Instance.call_exported_function(instance, name, params, from)
    {:noreply, state}
  end

  @impl true
  def handle_info({:returned_function_call, result, from}, state) do
    GenServer.reply(from, result)
    {:noreply, state}
  end

  @impl true
  def handle_info({:invoke_callback, namespace_name, import_name, context, params, token}, %{imports: imports} = state) do
    {success, return_value} = try do
      {:fn, _params, _returns, callback} = imports
                                      |> Map.get(namespace_name, %{})
                                      |> Map.get(import_name)
      {true, apply(callback, [context | params])}
    rescue
      e in RuntimeError -> {false, e.message}
    end

    :ok = Wasmex.Native.namespace_receive_callback_result(token, success, [return_value])
    {:noreply, state}
  end
end
