defmodule Wasmex.Memory do
  @moduledoc """
  A WebAssembly instance has its own memory, represented by the `Wasmex.Memory` struct.
  It is accessible by the `Wasmex.Instance.memory/2` getter.

  The `grow/2` method allows to grow the memory by a number of pages (of 64 kB or 65,536 bytes each).

  ```elixir
  Wasmex.Memory.grow(memory, 1)
  ```

  The current size of the memory can be obtained with the `length/1` method:

  ```elixir
  Wasmex.Memory.length(memory) # in bytes, always a multiple of the the page size (64 kB)
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

  ### Memory Buffer viewed in different Datatypes

  The `Wasmex.Memory` struct views the WebAssembly memory of an instance as an array of values of different types.
  Possible types are: `uint8`, `int8`, `uint16`, `int16`, `uint32`, and `int32`.
  The underlying data is not changed when viewed in different types - it is just its representation that changes.

  | View memory buffer as a sequence of… | Bytes per element |
  |----------|---|
  | `int8`   | 1 |
  | `uint8`  | 1 |
  | `int16`  | 2 |
  | `uint16` | 2 |
  | `int32`  | 4 |
  | `uint32` | 4 |

  This can be resolved at runtime:

  ```elixir
  {:ok, memory} = Wasmex.memory(instance, :uint16, 0)
  Wasmex.Memory.bytes_per_element(memory) # 2
  ```

  Since the same memory seen in different data types uses the same buffer internally. Let's have some fun:

  ```elixir
  int8 = Wasmex.memory(instance, :int8, 0)
  int16 = Wasmex.memory(instance, :int16, 0)
  int32 = Wasmex.memory(instance, :int32, 0)

                          b₁
                      ┌┬┬┬┬┬┬┐
  Memory.set(int8, 0, 0b00000001)
                          b₂
                      ┌┬┬┬┬┬┬┐
  Memory.set(int8, 1, 0b00000100)
                          b₃
                      ┌┬┬┬┬┬┬┐
  Memory.set(int8, 2, 0b00010000)
                          b₄
                      ┌┬┬┬┬┬┬┐
  Memory.set(int8, 3, 0b01000000)

  # Viewed in `int16`, 2 bytes are read per value
              b₂       b₁
          ┌┬┬┬┬┬┬┐ ┌┬┬┬┬┬┬┐
  assert 0b00000100_00000001 == Memory.get(int16, 0)
              b₄       b₃
          ┌┬┬┬┬┬┬┐ ┌┬┬┬┬┬┬┐
  assert 0b01000000_00010000 == Memory.get(int16, 1)

  # Viewed in `int32`, 4 bytes are read per value
              b₄       b₃       b₂       b₁
          ┌┬┬┬┬┬┬┐ ┌┬┬┬┬┬┬┐ ┌┬┬┬┬┬┬┐ ┌┬┬┬┬┬┬┐
  assert 0b01000000_00010000_00000100_00000001 == Memory.get(int32, 0)
  ```
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
            reference: nil

  @spec from_instance(Wasmex.StoreOrCaller.t(), Wasmex.Instance.t()) ::
          {:ok, t} | {:error, binary()}
  def from_instance(store_or_caller, instance) do
    %{resource: store_or_caller_resource} = store_or_caller
    %Wasmex.Instance{resource: instance_resource} = instance

    case Wasmex.Native.memory_from_instance(store_or_caller_resource, instance_resource) do
      {:ok, memory_resource} -> {:ok, wrap_resource(memory_resource)}
      {:error, err} -> {:error, err}
    end
  end

  def wrap_resource(resource) do
    %__MODULE__{
      resource: resource,
      reference: make_ref()
    }
  end

  @doc """
  Returns the number of elements that fit into memory.

  Note that the WebAssembly memory consists of pages of 65kb each.

  ```elixir
  {:ok, memory} = Wasmex.Memory.from_instance(store_or_caller, instance)
  Wasmex.Memory.length(store_or_caller, memory) # 1114112 (17 * 65_536)
  ```
  """
  @spec length(Wasmex.StoreOrCaller.t(), t()) :: pos_integer()
  def length(store_or_caller, memory) do
    %Wasmex.StoreOrCaller{resource: store_or_caller_resource} = store_or_caller
    %__MODULE__{resource: memory_resource} = memory
    Wasmex.Native.memory_length(store_or_caller_resource, memory_resource)
  end

  @doc """
  Grows the amount of available memory by the given number of pages and returns the number of previously available pages.
  Note that the maximum number of pages is `65_536`
  """
  @spec grow(Wasmex.StoreOrCaller.t(), t(), pos_integer()) :: pos_integer()
  def grow(store_or_caller, memory, pages) do
    %Wasmex.StoreOrCaller{resource: store_or_caller_resource} = store_or_caller
    %__MODULE__{resource: memory_resource} = memory
    Wasmex.Native.memory_grow(store_or_caller_resource, memory_resource, pages)
  end

  @spec get_byte(Wasmex.StoreOrCaller.t(), t(), non_neg_integer()) ::
          number()
  def get_byte(store_or_caller, memory, index) do
    %{resource: store_or_caller_resource} = store_or_caller
    %__MODULE__{resource: memory_resource} = memory

    Wasmex.Native.memory_get_byte(store_or_caller_resource, memory_resource, index)
  end

  @spec set_byte(Wasmex.StoreOrCaller.t(), t(), non_neg_integer(), number()) ::
          :ok | {:error, binary()}
  def set_byte(store_or_caller, memory, index, value) do
    %{resource: store_or_caller_resource} = store_or_caller
    %__MODULE__{resource: memory_resource} = memory

    Wasmex.Native.memory_set_byte(store_or_caller_resource, memory_resource, index, value)
  end

  @spec write_binary(
          Wasmex.StoreOrCaller.t(),
          t(),
          non_neg_integer(),
          binary()
        ) ::
          :ok
  def write_binary(store_or_caller, memory, index, str) when is_binary(str) do
    %Wasmex.StoreOrCaller{resource: store_or_caller_resource} = store_or_caller
    %__MODULE__{resource: memory_resource} = memory

    Wasmex.Native.memory_write_binary(
      store_or_caller_resource,
      memory_resource,
      index,
      str
    )
  end

  @spec read_binary(
          Wasmex.StoreOrCaller.t(),
          t(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          binary()
  def read_binary(store_or_caller, memory, index, length) do
    %Wasmex.StoreOrCaller{resource: store_or_caller_resource} = store_or_caller
    %__MODULE__{resource: memory_resource} = memory

    Wasmex.Native.memory_read_binary(
      store_or_caller_resource,
      memory_resource,
      index,
      length
    )
  end

  @spec read_string(
          Wasmex.StoreOrCaller.t(),
          t(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          String.t()
  def read_string(store, memory, index, length) do
    read_binary(store, memory, index, length)
    |> to_string()
  end
end

defimpl Inspect, for: Wasmex.Memory do
  import Inspect.Algebra

  def inspect(dict, opts) do
    concat(["#Wasmex.Memory<", to_doc(dict.reference, opts), ">"])
  end
end
