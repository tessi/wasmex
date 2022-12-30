defmodule Wasmex.Wasi.WasiOptions do
  @moduledoc ~S"""
  WASI Options
  """

  alias Wasmex.Wasi.PreopenOptions
  alias Wasmex.Pipe

  defstruct [:stdin, :stdout, :stderr, args: [], env: %{}, preopen: []]

  @type t :: %__MODULE__{
          args: [String.t()],
          env: %{String.t() => String.t()},
          preopen: [PreopenOptions],
          stdin: Pipe | nil,
          stdout: Pipe | nil,
          stderr: Pipe | nil
        }
end
