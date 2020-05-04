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

  @doc """
  Starts a GenServer which compiles and instantiates a WASM module from the given bytes and imports map.

  ```elixir
  imports = %{
    env: %{
      add_ints: {:fn, [:i32, :i32], [:i32], fn (_context, a, b) -> a + b end},
    }
  }
  {:ok, bytes } = File.read("wasmex_test.wasm")
  {:ok, instance } = Wasmex.start_link(%{bytes: bytes, imports: imports})

  {:ok, [42]} == Wasmex.call_function(instance, "sum", [50, -8])
  ```

  Imports are given as a map of namespaces.
  In the example above, we import the `"env"` namespace.
  Each namespace is, again, a map listing imports.
  Under the name `add_ints`, we imported a function which is represented with a tuple of:

  1. the import type: `:fn` (a function),
  1. the functions parameter types: `[:i32, :i32]`,
  1. the functions return types: `[:i32]`, and
  1. a function reference: `fn (_context, a, b, c) -> a + b end`

  When the WASM runtime executes the `add_ints` imported function, the execution context is forwarded to
  the given function reference.
  The first param is always the call context (a Map containing e.g. the instances memory).
  All other params are regular parameters as specified by the parameter type list.

  Valid parameter/return types are:

  - `:i32` a 32 bit integer
  - `:i64` a 64 bit integer
  - `:f32` a 32 bit float
  - `:f64` a 64 bit float

  The return type must always be one value.
  """
  def start_link(%{bytes: bytes, imports: imports, wasi: wasi})
      when is_binary(bytes) and is_map(imports) and is_map(wasi) do
    GenServer.start_link(__MODULE__, %{
      bytes: bytes,
      imports: stringify_keys(imports),
      wasi: stringify_keys(wasi)
    })
  end

  def start_link(%{bytes: bytes, imports: imports}) when is_binary(bytes) do
    GenServer.start_link(__MODULE__, %{bytes: bytes, imports: stringify_keys(imports), wasi: %{}})
  end

  def start_link(bytes) when is_binary(bytes) do
    start_link(%{bytes: bytes, imports: %{}, wasi: %{}})
  end

  @doc """
  Returns whether a function export with the given `name` exists in the WebAssembly instance.
  """
  def function_exists(pid, name) do
    GenServer.call(pid, {:exported_function_exists, stringify(name)})
  end

  @doc """
  Calls a function with the given `name` and `params` on
  the WebAssembly instance and returns its results.
  """
  def call_function(pid, name, params) do
    GenServer.call(pid, {:call_function, stringify(name), params})
  end

  @doc """
  Finds the exported memory of the given WASM instance and returns it as a `Wasmex.Memory`.

  The memory is a collection of bytes which can be viewed and interpreted as a sequence of different
  (data-)`types`:

  * uint8 / int8 - (un-)signed 8-bit integer values
  * uint16 / int16 - (un-)signed 16-bit integer values
  * uint32 / int32 - (un-)signed 32-bit integer values

  We can think of it as a list of values of the above type (where each value may be larger than a byte).
  The `offset` value can be used to start reading the memory from a chosen position.
  """
  def memory(pid, type, offset) when type in [:uint8, :int8, :uint16, :int16, :uint32, :int32] do
    GenServer.call(pid, {:memory, type, offset})
  end

  defp stringify_keys(atom_key_map) when is_map(atom_key_map) do
    for {key, val} <- atom_key_map, into: %{}, do: {stringify(key), stringify_keys(val)}
  end

  defp stringify_keys(value), do: value

  defp stringify(s) when is_binary(s), do: s
  defp stringify(s) when is_atom(s), do: Atom.to_string(s)

  # Server

  @doc """
  Params:

  * bytes (binary): the WASM bites defining the WASM module
  * imports (map): a map defining imports. Structure is:
                   %{
                     namespace_name: %{
                       import_name: {:fn, [:i32, :i32], [:i32], function_reference}
                     }
                   }
  """
  @impl true
  def init(%{bytes: bytes, imports: imports, wasi: wasi})
      when is_binary(bytes) and is_map(imports) and is_map(wasi) and map_size(wasi) == 0 do
    {:ok, instance} = Wasmex.Instance.from_bytes(bytes, imports)
    {:ok, %{instance: instance, imports: imports, wasi: wasi}}
  end

  @impl true
  def init(%{bytes: bytes, imports: imports, wasi: wasi})
      when is_binary(bytes) and is_map(imports) and is_map(wasi) and map_size(wasi) <= 2 do
    {:ok, instance} = Wasmex.Instance.wasi_from_bytes(bytes, imports, wasi)
    {:ok, %{instance: instance, imports: imports, wasi: wasi}}
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
  def handle_info(
        {:invoke_callback, namespace_name, import_name, context, params, token},
        %{imports: imports} = state
      ) do
    context =
      Map.put(
        context,
        :memory,
        Wasmex.Memory.wrap_resource(Map.get(context, :memory), :uint8, 0)
      )

    {success, return_value} =
      try do
        {:fn, _params, _returns, callback} =
          imports
          |> Map.get(namespace_name, %{})
          |> Map.get(import_name)

        {true, apply(callback, [context | params])}
      rescue
        e in RuntimeError -> {false, e.message}
      end

    return_values =
      case return_value do
        nil -> []
        _ -> [return_value]
      end

    :ok = Wasmex.Native.namespace_receive_callback_result(token, success, return_values)
    {:noreply, state}
  end
end
