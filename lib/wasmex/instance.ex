defmodule Wasmex.Instance do
  @moduledoc """
  Instantiates a WebAssembly module represented by bytes and allows calling exported functions on it.

  ```elixir
  # Get the Wasm module as bytes.
  {:ok, bytes } = File.read("wasmex_test.wasm")

  # Instantiates the Wasm module.
  {:ok, instance } = Wasmex.Instance.from_bytes(bytes)

  # Test for existence of a function
  true = Wasmex.Instance.function_export_exists(instance, "sum")
  ```

  All exported functions are accessible via `call_exported_function`.
  Arguments of these functions are automatically casted to WebAssembly values.
  Note that WebAssembly only knows number datatypes (floats and integers of various sizes).

  You can pass arbitrary data to WebAssembly, though, by writing this data into its memory. The `memory` function returns a `Memory` struct representing the memory of that particular instance, e.g.:

  ```elixir
  {:ok, memory} = Wasmex.Instance.memory(instance, :uint8, 0)
  ```

  This module, especially `call_exported_function` is assumed to be called within a GenServer context.
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
            # It also serves as a handy way to tell file handles apart.
            reference: nil

  @spec from_bytes(binary()) :: {:error, binary()} | {:ok, __MODULE__.t()}
  def from_bytes(bytes) when is_binary(bytes) do
    case Wasmex.Native.instance_new_from_bytes(bytes) do
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
  The result either is an `{:error, reason}` or `{:ok, results}` tuple with `results`
  containing a list of the results form the called WebAssembly function.

  Calling `call_exported_function` usually returns an `:ok` atom but may throw a BadArg exception when given
  unexpected input data. 
  """
  @spec call_exported_function(__MODULE__.t(), binary(), [any()], GenServer.from()) :: any()
  def call_exported_function(%__MODULE__{resource: resource}, name, params, from)
      when is_binary(name) do
    Wasmex.Native.instance_call_exported_function(resource, name, params, from)
  end

  @spec memory(__MODULE__.t(), atom(), pos_integer()) ::
          {:error, binary()} | {:ok, Wasmex.Memory.t()}
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
