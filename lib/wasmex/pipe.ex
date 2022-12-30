defmodule Wasmex.Pipe do
  @moduledoc """
  A Pipe is a memory buffer that can be used in exchange for a WASM file.

  It can be used, for example, to capture stdout/stdin/stderr of a WASI program.
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

  @doc false
  def wrap_resource(resource) do
    %__MODULE__{
      resource: resource,
      reference: make_ref()
    }
  end

  @doc """
  Creates and returns a new Pipe.
  """
  @spec create() :: {:error, reason :: binary()} | {:ok, __MODULE__.t()}
  def create() do
    case Wasmex.Native.pipe_create() do
      {:ok, resource} -> {:ok, wrap_resource(resource)}
      {:error, err} -> {:error, err}
    end
  end

  @doc """
  Returns the current size of the Pipe in bytes.
  """
  @spec size(__MODULE__.t()) :: integer()
  def size(%__MODULE__{resource: resource}) do
    Wasmex.Native.pipe_size(resource)
  end

  @doc """
  Sets the read/write position of the Pipe to the given position.

  The position is given as a number of bytes from the start of the Pipe.
  """
  @spec seek(__MODULE__.t(), integer()) :: :ok | :error
  def seek(%__MODULE__{resource: resource}, pos_from_start) do
    Wasmex.Native.pipe_seek(resource, pos_from_start)
  end

  @doc """
  Reads all available bytes from the Pipe and returns them as a binary.

  Note that this will not block if there are no bytes available.
  Reading starts at the current read position, see seek/2.
  """
  @spec read(__MODULE__.t()) :: binary()
  def read(%__MODULE__{resource: resource}) do
    Wasmex.Native.pipe_read_binary(resource)
  end

  @doc """
  Writes the given binary into the pipe.

  Writing starts at the current write position, see seek/2.
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
