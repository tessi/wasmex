defmodule Wasmex.Memory do
  @typedoc """
  TBD
  """

  @type t :: %__MODULE__{
    resource: binary(),
    reference: reference(),
  }

  defstruct [
    # The actual NIF memory resource.
    resource: nil,
    # Normally the compiler will happily do stuff like inlining the
    # resource in attributes. This will convert the resource into an
    # empty binary with no warning. This will make that harder to
    # accidentaly do.
    # It also serves as a handy way to tell file handles apart.
    reference: nil,
    size: nil,
    offset: nil
  ]

  @spec from_instance(Wasmex.Instance.t(), atom(), pos_integer()) :: __MODULE__.t()
  def from_instance(%Wasmex.Instance{resource: resource}, size, offset) when size in [:uint8, :int8, :uint16, :int16, :uint32, :int32] do
    case Wasmex.Native.memory_from_instance(resource) do
      {:ok, resource} -> {:ok, wrap_resource(resource, size, offset)}
      {:error, err} -> {:error, err}
    end
  end
  
  defp wrap_resource(resource, size, offset) do
    %__MODULE__{
      resource: resource,
      reference: make_ref(),
      size: size,
      offset: offset
    }
  end

  @spec bytes_per_element(__MODULE__.t()) :: pos_integer()
  def bytes_per_element(%Wasmex.Memory{} = memory) do
    bytes_per_element(memory, memory.size, memory.offset)
  end

  @spec bytes_per_element(__MODULE__.t(), atom(), pos_integer()) :: pos_integer()
  def bytes_per_element(%Wasmex.Memory{resource: resource}, size, offset) do
    Wasmex.Native.memory_bytes_per_element(resource, size, offset)
  end

  @spec length(__MODULE__.t()) :: pos_integer()
  def length(%Wasmex.Memory{} = memory) do
    length(memory, memory.size, memory.offset)
  end

  @spec length(__MODULE__.t(), atom(), pos_integer()) :: pos_integer()
  def length(%Wasmex.Memory{resource: resource}, size, offset) do
    Wasmex.Native.memory_length(resource, size, offset)
  end

  @spec grow(__MODULE__.t(), pos_integer()) :: pos_integer()
  def grow(%Wasmex.Memory{} = memory, pages) do
    grow(memory, memory.size, memory.offset, pages)
  end

  @spec grow(__MODULE__.t(), atom(), pos_integer(), pos_integer()) :: pos_integer()
  def grow(%Wasmex.Memory{resource: resource}, size, offset, pages) do
    Wasmex.Native.memory_grow(resource, size, offset, pages)
  end

  @spec get(__MODULE__.t(), pos_integer()) :: number()
  def get(%Wasmex.Memory{} = memory, index) do
    get(memory, memory.size, memory.offset, index)
  end

  @spec get(__MODULE__.t(), atom(), pos_integer(), pos_integer()) :: number()
  def get(%Wasmex.Memory{resource: resource}, size, offset, index) do
    Wasmex.Native.memory_get(resource, size, offset, index)
  end

  @spec set(__MODULE__.t(), pos_integer(), number()) :: number()
  def set(%Wasmex.Memory{} = memory, index, value) do
    set(memory, memory.size, memory.offset, index, value)
  end

  @spec set(__MODULE__.t(), atom(), pos_integer(), pos_integer(), number()) :: number()
  def set(%Wasmex.Memory{resource: resource}, size, offset, index, value) do
    Wasmex.Native.memory_set(resource, size, offset, index, value)
  end

  @spec write_binary(__MODULE__.t(), pos_integer(), binary()) :: :ok
  def write_binary(%Wasmex.Memory{} = memory, index, str) when is_binary(str) do
    write_binary(memory, memory.size, memory.offset, index, str)
  end

  @spec write_binary(__MODULE__.t(), atom(), pos_integer(), pos_integer(), binary()) :: :ok
  def write_binary(%Wasmex.Memory{resource: resource}, size, offset, index, str) when is_binary(str) do
    str = str <> "\0" # strings a null-byte terminated in C-land
    Wasmex.Native.memory_write_binary(resource, size, offset, index, str)
  end
end

defimpl Inspect, for: Wasmex.Memory do
  import Inspect.Algebra

  def inspect(dict, opts) do
    concat ["#Wasmex.Memory<", to_doc(dict.reference, opts), ">"]
  end
end