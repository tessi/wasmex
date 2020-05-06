defmodule Wasmex.Memory do
  @moduledoc """
  A WebAssembly instance has its own memory, represented by the `Memory` struct.
  It is accessible by the `Wasmex.Instance.memory` getter.

  The `Memory.grow` methods allows to grow the memory by a number of pages (of 65kb each).

  ```elixir
  Wasmex.Memory.grow(memory, 1)
  ```

  The current size of the memory can be obtained with the `length` method:

  ```elixir
  Wasmex.Memory.length(memory) # in bytes, always a multiple of the the page size (65kb)
  ```

  When creating the memory struct, the `offset` param can be provided, to subset the memory array at a particular offset.

  ```elixir
  offset = 7
  index = 4
  value = 42

  {:ok, memory} = Wasmex.Instance.memory(instance, :uint8, offset)
  Wasmex.Memory.set(memory, index, value)
  IO.puts Wasmex.Memory.get(memory, index) # 42
  ```

  The `Memory` struct views the WebAssembly memory of an instance as an array of values of different types.
  Possible types are: `uint8`, `int8`, `uint16`, `int16`, `uint32`, and `int32`.
  The underlying data is not changed when viewed in different types - its just its representation that changes.

  | View memory buffer as a sequence of… | Bytes per element |
  |----------|---|
  | `int8`   | 1 |
  | `uint8`  | 1 |
  | `int16`  | 2 |
  | `uint16` | 2 |
  | `int32`  | 4 |
  | `uint32` | 4 |
  """

  @type t :: %__MODULE__{
          resource: binary(),
          reference: reference()
        }

  defstruct resource: nil,
            # The actual NIF memory resource.
            # Normally the compiler will happily do stuff like inlining the
            # resource in attributes. This will convert the resource into an
            # empty binary with no warning. This will make that harder to
            # accidentally do.
            # It also serves as a handy way to tell file handles apart.
            reference: nil,
            size: nil,
            offset: nil

  @spec from_instance(Wasmex.Instance.t()) :: {:error, binary()} | {:ok, __MODULE__.t()}
  def from_instance(%Wasmex.Instance{} = instance) do
    from_instance(instance, :uint8, 0)
  end

  @spec from_instance(Wasmex.Instance.t(), atom(), non_neg_integer()) ::
          {:error, binary()} | {:ok, __MODULE__.t()}
  def from_instance(%Wasmex.Instance{resource: resource}, size, offset)
      when size in [:uint8, :int8, :uint16, :int16, :uint32, :int32] do
    case Wasmex.Native.memory_from_instance(resource) do
      {:ok, resource} -> {:ok, wrap_resource(resource, size, offset)}
      {:error, err} -> {:error, err}
    end
  end

  def wrap_resource(resource, size, offset) do
    %__MODULE__{
      resource: resource,
      reference: make_ref(),
      size: size,
      offset: offset
    }
  end

  @doc """
  Returns the number of bytes used to represent a unit in memory.

  For the limited number of unit sizes the byte values are the following:

   size | Bytes per element |
  |----------|---|
  | `int8`   | 1 |
  | `uint8`  | 1 |
  | `int16`  | 2 |
  | `uint16` | 2 |
  | `int32`  | 4 |
  | `uint32` | 4 |

  ```elixir
  {:ok, memory} = Wasmex.Instance.memory(instance, :uint16, 0)
  Wasmex.Memory.bytes_per_element(memory) # 2
  ```
  """
  @spec bytes_per_element(__MODULE__.t()) :: pos_integer()
  def bytes_per_element(%Wasmex.Memory{} = memory) do
    bytes_per_element(memory, memory.size, memory.offset)
  end

  @doc """
  Same as bytes_per_element/1 except the unit `size` and offset given at memory creation are overwritten by the given values.

  ```elixir
  {:ok, memory} = Wasmex.Instance.memory(instance)
  Wasmex.Memory.bytes_per_element(memory, :uint32, 0) # 4
  ```
  """
  @spec bytes_per_element(__MODULE__.t(), atom(), non_neg_integer()) :: pos_integer()
  def bytes_per_element(%Wasmex.Memory{resource: resource}, size, offset) do
    Wasmex.Native.memory_bytes_per_element(resource, size, offset)
  end

  @doc """
  Returns the number of elements that fit into memory for the given unit size and offset.

  Note that the WebAssembly memory consists of pages of 65kb each.
  Different unit `size`s needs a different number of bytes per element and the `offset` may reduce the number of available elements.

  ```elixir
  {:ok, memory} = Wasmex.Memory.from_instance(instance, :uint8, 0)
  Wasmex.Memory.length(memory) # 1114112 (17 * 65_536)
  ```
  """
  @spec length(__MODULE__.t()) :: pos_integer()
  def length(%Wasmex.Memory{} = memory) do
    length(memory, memory.size, memory.offset)
  end

  @doc """
  Same as length/1 except the unit `size` and offset given at memory creation are overwritten by the given values.

  ```elixir
  {:ok, memory} = Wasmex.Instance.memory(instance)
  Wasmex.Memory.length(memory, :uint8, 0) # 1114112 (17 * 65_536)
  ```
  """
  @spec length(__MODULE__.t(), atom(), non_neg_integer()) :: pos_integer()
  def length(%Wasmex.Memory{resource: resource}, size, offset) do
    Wasmex.Native.memory_length(resource, size, offset)
  end

  @doc """
  Grows the amount of available memory by the given number of pages and returns the number of previously available pages.
  Note that the maximum number of pages is `65_536`
  """
  @spec grow(__MODULE__.t(), pos_integer()) :: pos_integer()
  def grow(%Wasmex.Memory{} = memory, pages) do
    grow(memory, memory.size, memory.offset, pages)
  end

  @spec grow(__MODULE__.t(), atom(), non_neg_integer(), pos_integer()) :: pos_integer()
  def grow(%Wasmex.Memory{resource: resource}, size, offset, pages) do
    Wasmex.Native.memory_grow(resource, size, offset, pages)
  end

  @spec get(__MODULE__.t(), pos_integer()) :: number()
  def get(%Wasmex.Memory{} = memory, index) do
    get(memory, memory.size, memory.offset, index)
  end

  @spec get(__MODULE__.t(), atom(), non_neg_integer(), pos_integer()) :: number()
  def get(%Wasmex.Memory{resource: resource}, size, offset, index) do
    Wasmex.Native.memory_get(resource, size, offset, index)
  end

  @spec set(__MODULE__.t(), non_neg_integer(), number()) :: number()
  def set(%Wasmex.Memory{} = memory, index, value) do
    set(memory, memory.size, memory.offset, index, value)
  end

  @spec set(__MODULE__.t(), atom(), non_neg_integer(), non_neg_integer(), number()) :: number()
  def set(%Wasmex.Memory{resource: resource}, size, offset, index, value) do
    Wasmex.Native.memory_set(resource, size, offset, index, value)
  end

  @spec write_binary(__MODULE__.t(), non_neg_integer(), binary()) :: :ok
  def write_binary(%Wasmex.Memory{} = memory, index, str) when is_binary(str) do
    write_binary(memory, memory.size, memory.offset, index, str)
  end

  @spec write_binary(__MODULE__.t(), atom(), non_neg_integer(), non_neg_integer(), binary()) ::
          :ok
  def write_binary(%Wasmex.Memory{resource: resource}, size, offset, index, str)
      when is_binary(str) do
    Wasmex.Native.memory_write_binary(resource, size, offset, index, str)
  end

  @spec read_binary(t, non_neg_integer(), non_neg_integer()) :: binary()
  def read_binary(%Wasmex.Memory{} = memory, index, length) do
    read_binary(memory, memory.size, memory.offset, index, length)
  end

  @spec read_binary(
          __MODULE__.t(),
          atom(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          binary()
  def read_binary(%__MODULE__{resource: resource}, size, offset, index, length) do
    Wasmex.Native.memory_read_binary(resource, size, offset, index, length)
  end

  @spec read_string(t, non_neg_integer(), non_neg_integer()) :: String.t()
  def read_string(memory, index, length) do
    read_binary(memory, index, length)
    |> to_string()
  end

  @spec read_string(
          t,
          atom(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          String.t()
  def read_string(memory, size, offset, index, length) do
    read_binary(memory, size, offset, index, length)
    |> to_string()
  end
end

defimpl Inspect, for: Wasmex.Memory do
  import Inspect.Algebra

  def inspect(dict, opts) do
    concat(["#Wasmex.Memory<", to_doc(dict.reference, opts), ">"])
  end
end
