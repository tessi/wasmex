defmodule Wasmex.Pipe do
  @moduledoc ~S"""
  A Pipe is a memory buffer that can be used in exchange for a Wasm file.

  Pipes have a read and write position which can be set using `seek/2`.

  Each pipe retains at most 256 MiB by default, independently of store memory
  limits. Use `new/1` to configure this limit. Reads advance the cursor without
  freeing the retained buffer. The limit covers the total buffer extent,
  including gaps introduced by seeking, rather than unread bytes or all VM memory.

  ## Example

  Pipes can be written to and read from:

      iex> {:ok, pipe} = Wasmex.Pipe.new()
      iex> Wasmex.Pipe.write(pipe, "hello")
      {:ok, 5}
      iex> Wasmex.Pipe.seek(pipe, 0)
      iex> Wasmex.Pipe.read(pipe)
      "hello"

  They can be used to capture stdout/stdin/stderr of WASI programs:

      iex> {:ok, stdin} = Wasmex.Pipe.new()
      iex> {:ok, stdout} = Wasmex.Pipe.new()
      iex> {:ok, stderr} = Wasmex.Pipe.new()
      iex> Wasmex.Store.new_wasi(%Wasmex.Wasi.WasiOptions{
      ...>   stdin: stdin,
      ...>   stdout: stdout,
      ...>   stderr: stderr,
      ...> })
  """

  @type t :: %__MODULE__{
          resource: binary(),
          reference: reference()
        }

  defstruct resource: nil,
            # The actual NIF pipe resource.
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
  Creates and returns a new Pipe.

  The optional `:max_size` is a non-negative maximum retained buffer size in
  bytes, defaulting to 256 MiB (268,435,456 bytes). Larger workloads can opt into
  a higher limit. No buffer is allocated until the pipe is written to.

  ## Example

      iex> {:ok, %Wasmex.Pipe{}} = Wasmex.Pipe.new()

      iex> {:ok, %Wasmex.Pipe{}} = Wasmex.Pipe.new(max_size: 1024)
  """
  @spec new() :: {:error, reason :: binary()} | {:ok, __MODULE__.t()}
  @spec new(keyword()) :: {:error, reason :: binary()} | {:ok, __MODULE__.t()}
  def new(options \\ []) do
    resource =
      case Keyword.validate!(options, max_size: 256 * 1024 * 1024) do
        [max_size: max_size] when is_integer(max_size) and max_size >= 0 ->
          Wasmex.Native.pipe_new_with_limit(max_size)

        _ ->
          raise ArgumentError, "max_size must be a non-negative integer"
      end

    case resource do
      {:error, err} -> {:error, err}
      resource -> {:ok, __wrap_resource__(resource)}
    end
  end

  @doc ~S"""
  Returns the current size of the Pipe in bytes.

  ## Example

      iex> {:ok, pipe} = Wasmex.Pipe.new()
      iex> Wasmex.Pipe.size(pipe)
      0
      iex> Wasmex.Pipe.write(pipe, "hello")
      iex> Wasmex.Pipe.size(pipe)
      5
  """
  @spec size(__MODULE__.t()) :: integer()
  def size(%__MODULE__{resource: resource}) do
    Wasmex.Native.pipe_size(resource)
  end

  @doc ~S"""
  Sets the read/write position of the Pipe to the given position.

  The position is given as a number of bytes from the start of the Pipe.

  ## Example

      iex> {:ok, pipe} = Wasmex.Pipe.new()
      iex> Wasmex.Pipe.write(pipe, "hello")
      iex> Wasmex.Pipe.seek(pipe, 0)
      :ok
      iex> Wasmex.Pipe.read(pipe)
      "hello"
  """
  @spec seek(__MODULE__.t(), integer()) :: :ok | :error
  def seek(%__MODULE__{resource: resource}, pos_from_start) do
    Wasmex.Native.pipe_seek(resource, pos_from_start)
  end

  @doc ~S"""
  Reads all available bytes from the Pipe and returns them as a binary.

  This function does not block if there are no bytes available.
  Reading starts at the current read position, see `seek/2`, and forwards the read position to the end of the Pipe.
  The read bytes are not erased and can be read again after seeking back.

  ## Example

      iex> {:ok, pipe} = Wasmex.Pipe.new()
      iex> Wasmex.Pipe.write(pipe, "hello")
      iex> Wasmex.Pipe.read(pipe) # current position is at EOL, nothing more to read
      ""
      iex> Wasmex.Pipe.seek(pipe, 0)
      iex> Wasmex.Pipe.read(pipe)
      "hello"
      iex> Wasmex.Pipe.seek(pipe, 3)
      iex> Wasmex.Pipe.read(pipe)
      "lo"
      iex> Wasmex.Pipe.read(pipe)
      ""
  """
  @spec read(__MODULE__.t()) :: binary()
  def read(%__MODULE__{resource: resource}) do
    Wasmex.Native.pipe_read_binary(resource)
  end

  @doc ~S"""
  Writes the given binary into the pipe.

  Writing starts at the current write position, see `seek/2`, and forwards it.
  A write that would exceed the pipe's maximum buffer size returns `:error`
  without changing the buffer or cursor. WASI writes to a full pipe receive
  an I/O error. Writes are never silently truncated.

  ## Example

      iex> {:ok, pipe} = Wasmex.Pipe.new()
      iex> Wasmex.Pipe.write(pipe, "hello")
      {:ok, 5}
      iex> Wasmex.Pipe.seek(pipe, 0)
      iex> Wasmex.Pipe.read(pipe)
      "hello"
  """
  @spec write(__MODULE__.t(), binary()) :: {:ok, integer()} | :error
  def write(%__MODULE__{resource: resource}, binary) do
    Wasmex.Native.pipe_write_binary(resource, binary)
  end
end

defimpl Inspect, for: Wasmex.Pipe do
  import Inspect.Algebra

  def inspect(dict, opts) do
    concat(["#Wasmex.Pipe<", to_doc(dict.reference, opts), ">"])
  end
end
