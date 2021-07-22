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
  Returns the current size in bytes of the Pipe.
  """
  @spec size(__MODULE__.t()) :: integer()
  def size(%__MODULE__{resource: resource}) do
    Wasmex.Native.pipe_size(resource)
  end

  @doc """
  Attempts to resize the pipe to the given number of bytes.
  """
  @spec set_len(__MODULE__.t(), integer()) :: :ok | :error
  def set_len(%__MODULE__{resource: resource}, len) do
    Wasmex.Native.pipe_set_len(resource, len)
  end

  @doc """
  Reads all available bytes from the Pipe and returns them as a binary.
  """
  @spec read(__MODULE__.t()) :: binary()
  def read(%__MODULE__{resource: resource}) do
    Wasmex.Native.pipe_read_binary(resource)
  end

  @doc """
  Writes the given binary into the pipe.
  """
  @spec write(__MODULE__.t(), binary()) :: {:ok, integer()} | :error
  def write(%__MODULE__{resource: resource}, binary) do
    Wasmex.Native.pipe_write_binary(resource, binary)
  end
end
