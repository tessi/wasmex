defmodule Wasmex.Memory do
  @moduledoc """
  The memory is a linear array of bytes. The `Memory` module provides functions to read and write to this array.

  `Memory` is accessible through `Wasmex.Instance.memory/2` or `Wasmex.Memory.from_instance/2`).

  ```elixir
  {:ok, memory} = Wasmex.Instance.memory(store_or_caller, instance)
  Wasmex.Memory.set_byte(store_or_caller, memory, 0, 42)
  IO.puts Wasmex.Memory.get_byte(store_or_caller, memory, 0) # 42
  ```

  WASM memory is organized in pages of 64kb and may be grown by additional pages.
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

  @doc false
  def wrap_resource(resource) do
    %__MODULE__{
      resource: resource,
      reference: make_ref()
    }
  end

  @doc """
  Returns the default memory resource of the given instance.

  ```elixir
  {:ok, memory} = Wasmex.Memory.from_instance(store_or_caller, instance)
  ```
  """
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

  @doc """
  Returns the size in of bytes of the given memory.

  Note that the size of the memory is always a multiple of 64kb (one page).

  ```elixir
  {:ok, memory} = Wasmex.Memory.from_instance(store_or_caller, instance)
  Wasmex.Memory.length(store_or_caller, memory) # 1114112 bytes (17 * 64 kB)
  ```
  """
  @spec length(Wasmex.StoreOrCaller.t(), t()) :: pos_integer()
  def length(store_or_caller, memory) do
    %Wasmex.StoreOrCaller{resource: store_or_caller_resource} = store_or_caller
    %__MODULE__{resource: memory_resource} = memory
    Wasmex.Native.memory_length(store_or_caller_resource, memory_resource)
  end

  @doc """
  Grows the amount of available memory by the given number of pages.

  Returns the number of previously available pages.
  A page has a size of 64 kB or 65,536 bytes.

  Returns an error if memory could not be grown.

  ```elixir
  _previous_amount_of_allocated_pages = Wasmex.Memory.grow(memory, 1)
  ```
  """
  @spec grow(Wasmex.StoreOrCaller.t(), t(), pos_integer()) :: pos_integer() | {:error, binary()}
  def grow(store_or_caller, memory, pages) do
    %Wasmex.StoreOrCaller{resource: store_or_caller_resource} = store_or_caller
    %__MODULE__{resource: memory_resource} = memory
    Wasmex.Native.memory_grow(store_or_caller_resource, memory_resource, pages)
  end

  @doc """
  Returns the byte at the given index.

  ```elixir
  # read value at memory position `0`
  Wasmex.Memory.get_byte(store_or_caller, memory, 0)
  ```
  """
  @spec get_byte(Wasmex.StoreOrCaller.t(), t(), non_neg_integer()) ::
          number()
  def get_byte(store_or_caller, memory, index) do
    %{resource: store_or_caller_resource} = store_or_caller
    %__MODULE__{resource: memory_resource} = memory

    Wasmex.Native.memory_get_byte(store_or_caller_resource, memory_resource, index)
  end

  @doc """
  Sets the byte at the given index to the given value.

  ```elixir
  # write value `42` at memory position `0`
  Wasmex.Memory.set_byte(store_or_caller, memory, 0, 42)
  ```
  """
  @spec set_byte(Wasmex.StoreOrCaller.t(), t(), non_neg_integer(), number()) ::
          :ok | {:error, binary()}
  def set_byte(store_or_caller, memory, index, value) do
    %{resource: store_or_caller_resource} = store_or_caller
    %__MODULE__{resource: memory_resource} = memory

    Wasmex.Native.memory_set_byte(store_or_caller_resource, memory_resource, index, value)
  end

  @doc """
  Writes the given binary to the given memory at the given index.

  ```elixir
  # Writes 5 bytes representing the ASCII characters for "hello"
  # at memory position `0`
  Wasmex.Instance.memory(store_or_caller, memory, 0, "hello")
  ```
  """
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

  @doc """
  Reads the given number of bytes from the given memory at the given index.

  Returns the read bytes as a binary.

  ```elixir
  # Reads 5 bytes from memory position `0`, given it contains the 5 ASCII
  # characters forming "hello".
  Wasmex.Memory.read_binary(store, memory, 0, 5) == 'hello'

  # Reads 2 bytes from memory position `3`
  Wasmex.Memory.read_binary(store, memory, 3, 2) == 'lo'
  ```
  """
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

  @doc """
  Reads the given number of bytes from the given memory at the given index.

  Returns the read bytes as a string.

  ```elixir
  # Reads 5 bytes from memory position `0`, given it contains the 5 ASCII
  # characters forming "hello".
  Wasmex.Memory.read_string(store, memory, 0, 5) == "hello"

  # Reads 2 bytes from memory position `3`
  Wasmex.Memory.read_string(store, memory, 3, 2) == "lo"
  ```
  """
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
