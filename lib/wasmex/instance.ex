defmodule Wasmex.Instance do
  @moduledoc """
  Instantiates a WebAssembly module and allows calling exported functions on it.

      # Read a WASM file and compile it into a WASM module
      {:ok, bytes } = File.read("wasmex_test.wasm")
      {:ok, module} = Wasmex.Module.compile(bytes)

      # Instantiates the WASM module.
      {:ok, instance } = Wasmex.start_link(%{module: module})

      # Call a function on it.
      {:ok, [result]} = Wasmex.call_function(instance, "sum", [1, 2])

      IO.puts result # 3

  All exported functions are accessible via `call_exported_function`.
  Arguments of these functions are automatically casted to WebAssembly values.
  Note that WebAssembly only knows number datatypes (floats and integers of various sizes).

  You can pass arbitrary data to WebAssembly by writing data into an instances memory. The `memory/3` function returns a `Wasmex.Memory` struct representing the memory of an instance, e.g.:

  ```elixir
  {:ok, memory} = Wasmex.Instance.memory(instance, :uint8, 0)
  ```

  This module, especially `call_exported_function/4`, is assumed to be called within a GenServer context.
  Usually, functions definedd here are called through the `Wasmex` module API to satisfy this assumption.
  """

  @type t :: %__MODULE__{
          resource: binary(),
          reference: reference()
        }

  defstruct resource: nil,
            # The actual NIF instance resource.
            # Normally the compiler will happily do stuff like inlining the
            # resource in attributes. This will convert the resource into an
            # empty binary with no warning. This will make that harder to
            # accidentally do.
            reference: nil

  @deprecated "Compile the module with Wasmex.Module.compile/1 and then use new/2 instead"
  @spec from_bytes(binary(), %{optional(binary()) => (... -> any())}) ::
          {:ok, __MODULE__.t()} | {:error, binary()}
  def from_bytes(bytes, imports) do
    case Wasmex.Module.compile(bytes) do
      {:ok, module} -> new(module, imports)
      error -> error
    end
  end

  @spec new(Wasmex.Module.t(), %{optional(binary()) => (... -> any())}) ::
          {:ok, __MODULE__.t()} | {:error, binary()}
  def new(%Wasmex.Module{resource: memory_resource}, imports) when is_map(imports) do
    case Wasmex.Native.instance_new(memory_resource, imports) do
      {:ok, resource} -> {:ok, wrap_resource(resource)}
      {:error, err} -> {:error, err}
    end
  end

  @deprecated "Compile the module with Wasmex.Module.compile/1 and then use new_wasi/3 instead"
  @spec wasi_from_bytes(binary(), %{optional(binary()) => (... -> any())}, %{
          optional(:args) => [String.t()],
          optional(:env) => %{String.t() => String.t()},
          optional(:stdin) => Wasmex.Pipe.t(),
          optional(:stdout) => Wasmex.Pipe.t(),
          optional(:stderr) => Wasmex.Pipe.t()
        }) ::
          {:ok, __MODULE__.t()} | {:error, binary()}
  def wasi_from_bytes(bytes, imports, wasi) do
    case Wasmex.Module.compile(bytes) do
      {:ok, module} -> new_wasi(module, imports, wasi)
      error -> error
    end
  end

  @spec new_wasi(Wasmex.Module.t(), %{optional(binary()) => (... -> any())}, %{
          optional(:args) => [String.t()],
          optional(:env) => %{String.t() => String.t()},
          optional(:stdin) => Wasmex.Pipe.t(),
          optional(:stdout) => Wasmex.Pipe.t(),
          optional(:stderr) => Wasmex.Pipe.t()
        }) ::
          {:ok, __MODULE__.t()} | {:error, binary()}
  def new_wasi(%Wasmex.Module{resource: memory_resource}, imports, wasi)
      when is_map(imports) and is_map(wasi) do
    args = Map.get(wasi, "args", [])
    env = Map.get(wasi, "env", %{})
    {opts, _} = Map.split(wasi, ["stdin", "stdout", "stderr", "preopen"])

    case Wasmex.Native.instance_new_wasi(memory_resource, imports, args, env, opts) do
      {:ok, resource} -> {:ok, wrap_resource(resource)}
      {:error, err} -> {:error, err}
    end
  end

  defp wrap_resource(resource) do
    %__MODULE__{
      resource: resource,
      reference: make_ref()
    }
  end

  @spec function_export_exists(__MODULE__.t(), binary()) :: boolean()
  def function_export_exists(%__MODULE__{resource: resource}, name) when is_binary(name) do
    Wasmex.Native.instance_function_export_exists(resource, name)
  end

  @doc """
  Calls a function with the given `name` and `params` on the WebAssembly `instance`.
  This function assumes to be called within a GenServer context, it expects a `from` argument
  as given by `handle_call` etc.

  The WebAssembly function will be invoked asynchronously in a new OS thread.
  The calling process will receive a `{:returned_function_call, result, from}` message once
  the execution finished.
  The result either is an `{:error, reason}` or the `:ok` atom.

  A BadArg exception may be thrown when given unexpected input data.
  """
  @spec call_exported_function(__MODULE__.t(), binary(), [any()], GenServer.from()) ::
          :ok | {:error, binary()}
  def call_exported_function(%__MODULE__{resource: resource}, name, params, from)
      when is_binary(name) do
    Wasmex.Native.instance_call_exported_function(resource, name, params, from)
  end

  @spec memory(__MODULE__.t(), atom(), pos_integer()) ::
          {:ok, Wasmex.Memory.t()} | {:error, binary()}
  def memory(%__MODULE__{} = instance, size, offset)
      when size in [:uint8, :int8, :uint16, :int16, :uint32, :int32] do
    Wasmex.Memory.from_instance(instance, size, offset)
  end
end

defimpl Inspect, for: Wasmex.Instance do
  import Inspect.Algebra

  def inspect(dict, opts) do
    concat(["#Wasmex.Instance<", to_doc(dict.reference, opts), ">"])
  end
end
