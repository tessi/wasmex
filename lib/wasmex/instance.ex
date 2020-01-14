defmodule Wasmex.Instance do
  @moduledoc """
  Instantiates a WebAssembly module represented by bytes and allows calling exported functions on it.

  ```elixir
  # Get the Wasm module as bytes.
  {:ok, bytes } = File.read("wasmex_test.wasm")

  # Instantiates the Wasm module.
  {:ok, instance } = Wasmex.Instance.from_bytes(bytes)

  # Call a function on it.
  result = Wasmex.Instance.call_exported_function(instance, "sum", [1, 2])

  IO.puts result # 3
  ```

  All exported functions are accessible via the `call_exported_function` function. Arguments of these functions are automatically casted to WebAssembly values.
  Note that WebAssembly only knows number datatypes (floats and integers of various sizes).

  You can pass arbritrary data to WebAssembly, though, by writing this data into its memory. The `memory` function returns a `Memory` struct representing the memory of that particular instance, e.g.:

  ```elixir
  {:ok, memory} = Wasmex.Instance.memory(instance, :uint8, 0)
  ```
  """
  @type wasm_bytes :: binary

  @type t :: %__MODULE__{
          resource: binary(),
          reference: reference()
        }

  defstruct resource: nil,
            # The actual NIF instance resource.
            # Normally the compiler will happily do stuff like inlining the
            # resource in attributes. This will convert the resource into an
            # empty binary with no warning. This will make that harder to
            # accidentaly do.
            # It also serves as a handy way to tell file handles apart.
            reference: nil

  @spec from_bytes(wasm_bytes) :: __MODULE__.t()
  def from_bytes(bytes) when is_binary(bytes) do
    case Wasmex.Native.instance_new_from_bytes(bytes) do
      {:error, err} -> {:error, err}
      {:ok, resource} -> {:ok, wrap_resource(resource)}
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

  @spec call_exported_function(__MODULE__.t(), binary()) :: any()
  def call_exported_function(%__MODULE__{} = instance, name) when is_binary(name) do
    call_exported_function(instance, name, [])
  end

  @spec call_exported_function(__MODULE__.t(), binary(), [any()]) :: any()
  def call_exported_function(%__MODULE__{resource: resource}, name, params)
      when is_binary(name) do
    Wasmex.Native.instance_call_exported_function(resource, name, params)
  end

  @spec memory(__MODULE__.t(), atom(), pos_integer()) :: Wasmex.Memory.t()
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
