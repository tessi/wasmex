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

  def start_link(bytes) when is_binary(bytes) do
    GenServer.start_link(__MODULE__, bytes)
  end

  def function_exists(pid, name) do
    GenServer.call(pid, {:exported_function_exists, name})
  end

  def call_function(pid, name, params) do
    GenServer.call(pid, {:call_function, name, params})
  end

  def memory(pid, size, offset) when size in [:uint8, :int8, :uint16, :int16, :uint32, :int32] do
    GenServer.call(pid, {:memory, size, offset})
  end

  # Server

  @impl true
  def init(bytes) when is_binary(bytes) do
    {:ok, instance} = Wasmex.Instance.from_bytes(bytes)
    {:ok, %{instance: instance}}
  end

  @impl true
  def handle_call({:memory, size, offset}, _from, %{instance: instance}) when size in [:uint8, :int8, :uint16, :int16, :uint32, :int32] do
    case Wasmex.Memory.from_instance(instance, size, offset) do
      {:ok, memory} -> {:reply, {:ok, memory}, %{instance: instance}}
      {:error, error} -> {:reply, {:error, error}, %{instance: instance}}
    end
  end

  @impl true
  def handle_call({:exported_function_exists, name}, _from, %{instance: instance}) when is_binary(name) do
    {:reply, Wasmex.Instance.function_export_exists(instance, name), %{instance: instance}}
  end

  @impl true
  def handle_call({:call_function, name, params}, from, %{instance: instance}) do
    :ok = Wasmex.Instance.call_exported_function(instance, name, params, from)
    {:noreply, %{instance: instance}}
  end

  @impl true
  def handle_info({:returned_function_call, result, from}, state) do
    GenServer.reply(from, result)
    {:noreply, state}
  end
end
