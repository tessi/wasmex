defmodule Wasmex.Wasi.PreopenOptions do
  @moduledoc ~S"""
  Options for preopening a directory.

  Likely to be extended with read/write permissions once wasmtime supports them.

  ## Options

    * `:path` - The path to the directory to preopen
    * `:alias` - The alias to use for the directory. The directory will be
      available at this path in the WASI filesystem. If not specified, the
      directory will be available at its real path.

  ## Example

        iex> Wasmex.Store.new_wasi(%Wasmex.Wasi.WasiOptions{
        ...>   preopen: [
        ...>     %PreopenOptions{path: "/tmp", alias: "temp"}
        ...>   ],
        ...> })
  """

  @enforce_keys [:path]
  defstruct [:path, alias: nil]
  @type t :: %__MODULE__{path: String.t(), alias: String.t() | nil}
end
