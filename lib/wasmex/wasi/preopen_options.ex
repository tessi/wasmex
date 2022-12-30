defmodule Wasmex.Wasi.PreopenOptions do
  @moduledoc ~S"""
  Options for preopening a directory.

  Likely to be extended with read/write permissions once wasmtime supports them.
  """

  @enforce_keys [:path]
  defstruct [:path, alias: nil]
  @type t :: %__MODULE__{path: String.t(), alias: String.t() | nil}
end
