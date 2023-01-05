defmodule Wasmex.Memory do
  @moduledoc ~S"""
  Memory is a linear array of bytes to store WASM values. The `Memory` module provides functions to read and write to this array.

  `Memory` is accessible through `Wasmex.Instance.memory/2`,
  `Wasmex.Memory.from_instance/2`, or as the caller context
  of an imported function (see `Wasmex.Instance.call_exported_function/5`).

      iex> %{store: store, module: module} = TestHelper.wasm_module()
      iex> {:ok, instance} = Wasmex.Instance.new(store, module, %{})
      iex> {:ok, memory} = Wasmex.Instance.memory(store, instance)
      iex> Wasmex.Memory.set_byte(store, memory, 0, 42)
      iex> Wasmex.Memory.get_byte(store, memory, 0)
      42

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

  def __wrap_resource__(resource) do
    %__MODULE__{
      resource: resource,
      reference: make_ref()
    }
  end

  @doc ~S"""
  Returns the exported memory resource of the given `Wasmex.Instance`.

  ## Example

      iex> %{store: store, module: module} = TestHelper.wasm_module()
      iex> {:ok, instance} = Wasmex.Instance.new(store, module, %{})
      iex> {:ok, %Wasmex.Memory{}} = Wasmex.Memory.from_instance(store, instance)
  """
  @spec from_instance(Wasmex.StoreOrCaller.t(), Wasmex.Instance.t()) ::
          {:ok, t} | {:error, binary()}
  def from_instance(store_or_caller, instance) do
    %{resource: store_or_caller_resource} = store_or_caller
    %Wasmex.Instance{resource: instance_resource} = instance

    case Wasmex.Native.memory_from_instance(store_or_caller_resource, instance_resource) do
      {:error, err} -> {:error, err}
      resource -> {:ok, __wrap_resource__(resource)}
    end
  end

  @doc ~S"""
  Returns the size in bytes of the given memory.

  Note that the size of the memory is always a multiple of 64kb (one page).

  ## Example

      iex> %{store: store, module: module} = TestHelper.wasm_module()
      iex> {:ok, instance} = Wasmex.Instance.new(store, module, %{})
      iex> {:ok, memory} = Wasmex.Memory.from_instance(store, instance)
      iex> Wasmex.Memory.size(store, memory)
      1114112 # in bytes (17 pages of 64 kB)
  """
  @spec size(Wasmex.StoreOrCaller.t(), t()) :: pos_integer()
  def size(store_or_caller, memory) do
    %Wasmex.StoreOrCaller{resource: store_or_caller_resource} = store_or_caller
    %__MODULE__{resource: memory_resource} = memory
    Wasmex.Native.memory_size(store_or_caller_resource, memory_resource)
  end

  @doc ~S"""
  Grows the amount of available memory by the given number of pages.

  Returns the number of previously available pages.
  A page has a size of 64 kB or 65,536 bytes.

  Returns an error if memory could not be grown.

  ## Example

      iex> %{store: store, module: module} = TestHelper.wasm_module()
      iex> {:ok, instance} = Wasmex.Instance.new(store, module, %{})
      iex> {:ok, memory} = Wasmex.Memory.from_instance(store, instance)
      iex> Wasmex.Memory.grow(store, memory, 1)
      17
  """
  @spec grow(Wasmex.StoreOrCaller.t(), t(), pos_integer()) :: pos_integer() | {:error, binary()}
  def grow(store_or_caller, memory, pages) do
    %Wasmex.StoreOrCaller{resource: store_or_caller_resource} = store_or_caller
    %__MODULE__{resource: memory_resource} = memory
    Wasmex.Native.memory_grow(store_or_caller_resource, memory_resource, pages)
  end

  @doc ~S"""
  Returns the byte at the given `index`.

  ## Example

  Set a value at memory position `0` and read it back:

      iex> %{store: store, module: module} = TestHelper.wasm_module()
      iex> {:ok, instance} = Wasmex.Instance.new(store, module, %{})
      iex> {:ok, memory} = Wasmex.Memory.from_instance(store, instance)
      iex> Wasmex.Memory.set_byte(store, memory, 0, 42)
      iex> Wasmex.Memory.get_byte(store, memory, 0)
      42
  """
  @spec get_byte(Wasmex.StoreOrCaller.t(), t(), non_neg_integer()) ::
          number()
  def get_byte(store_or_caller, memory, index) do
    %{resource: store_or_caller_resource} = store_or_caller
    %__MODULE__{resource: memory_resource} = memory

    Wasmex.Native.memory_get_byte(store_or_caller_resource, memory_resource, index)
  end

  @doc ~S"""
  Sets the byte at the given `index` to the given `value`.

  ## Example

  Set a value at memory position `0` and read it back:

      iex> %{store: store, module: module} = TestHelper.wasm_module()
      iex> {:ok, instance} = Wasmex.Instance.new(store, module, %{})
      iex> {:ok, memory} = Wasmex.Memory.from_instance(store, instance)
      iex> Wasmex.Memory.set_byte(store, memory, 0, 42)
      iex> Wasmex.Memory.get_byte(store, memory, 0)
      42
  """
  @spec set_byte(Wasmex.StoreOrCaller.t(), t(), non_neg_integer(), number()) ::
          :ok | {:error, binary()}
  def set_byte(store_or_caller, memory, index, value) do
    %{resource: store_or_caller_resource} = store_or_caller
    %__MODULE__{resource: memory_resource} = memory

    Wasmex.Native.memory_set_byte(store_or_caller_resource, memory_resource, index, value)
  end

  @doc ~S"""
  Writes the given `binary` into the memory at the given `index`.

  ## Example

  Writes 5 bytes representing the ASCII characters for "hello"
  at memory position `0`.

      iex> %{store: store, module: module} = TestHelper.wasm_module()
      iex> {:ok, instance} = Wasmex.Instance.new(store, module, %{})
      iex> {:ok, memory} = Wasmex.Memory.from_instance(store, instance)
      iex> Wasmex.Memory.write_binary(store, memory, 0, "hello")
      :ok
  """
  @spec write_binary(
          Wasmex.StoreOrCaller.t(),
          t(),
          non_neg_integer(),
          binary()
        ) ::
          :ok
  def write_binary(store_or_caller, memory, index, binary) when is_binary(binary) do
    %Wasmex.StoreOrCaller{resource: store_or_caller_resource} = store_or_caller
    %__MODULE__{resource: memory_resource} = memory

    Wasmex.Native.memory_write_binary(
      store_or_caller_resource,
      memory_resource,
      index,
      binary
    )
  end

  @doc ~S"""
  Reads the given number of bytes from the given memory at the given index.

  Returns the read bytes as a binary.

  ## Example

  Reads 5 bytes from memory position `0`, given it contains the 5 ASCII
  characters forming "hello".

      iex> %{store: store, module: module} = TestHelper.wasm_module()
      iex> {:ok, instance} = Wasmex.Instance.new(store, module, %{})
      iex> {:ok, memory} = Wasmex.Memory.from_instance(store, instance)
      iex> Wasmex.Memory.write_binary(store, memory, 0, "hello")
      iex> Wasmex.Memory.read_binary(store, memory, 0, 5)
      "hello"
      iex> Wasmex.Memory.read_binary(store, memory, 3, 2)
      "lo"
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

  @doc ~S"""
  Reads the given number of bytes from the given memory at the given index.

  Returns the read bytes as a string.

  ## Example

  Reads 5 bytes from memory position `0`, given it contains the 5 ASCII
  characters forming "hello".

      iex> %{store: store, module: module} = TestHelper.wasm_module()
      iex> {:ok, instance} = Wasmex.Instance.new(store, module, %{})
      iex> {:ok, memory} = Wasmex.Memory.from_instance(store, instance)
      iex> Wasmex.Memory.write_binary(store, memory, 0, "hello")
      iex> Wasmex.Memory.read_string(store, memory, 0, 5)
      "hello"
      iex> Wasmex.Memory.read_string(store, memory, 3, 2)
      "lo"
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
