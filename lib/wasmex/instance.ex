defmodule Wasmex.Instance do
  @typedoc """
  TBD
  """
  @type wasm_bytes :: binary

  @type t :: %__MODULE__{
    resource: binary(),
    reference: reference(),
  }

  defstruct [
    # The actual NIF instance resource.
    resource: nil,
    # Normally the compiler will happily do stuff like inlining the
    # resource in attributes. This will convert the resource into an
    # empty binary with no warning. This will make that harder to
    # accidentaly do.
    # It also serves as a handy way to tell file handles apart.
    reference: nil,
  ]

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
      reference: make_ref(),
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
  def call_exported_function(%__MODULE__{resource: resource}, name, params) when is_binary(name) do
    Wasmex.Native.instance_call_exported_function(resource, name, params)
  end

  @spec memory(__MODULE__.t(), atom(), pos_integer()) :: Wasmex.Memory.t()
  def memory(%__MODULE__{} = instance, size, offset) when size in [:uint8, :int8, :uint16, :int16, :uint32, :int32] do
    Wasmex.Memory.from_instance(instance, size, offset)
  end
end

defimpl Inspect, for: Wasmex.Instance do
  import Inspect.Algebra

  def inspect(dict, opts) do
    concat ["#Wasmex.Instance<", to_doc(dict.reference, opts), ">"]
  end
end