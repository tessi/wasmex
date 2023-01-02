defmodule Wasmex.Wasi.WasiOptions do
  @moduledoc ~S"""
  Configures WASI support for a Wasmex.Store.

  ## Options

    * `:args` - A list of command line arguments
    * `:env` - A map of environment variables
    * `:preopen` - A list of `Wasmex.Wasi.PreopenOptions` to preopen directories
    * `:stdin` - A `Wasmex.Pipe` to use as stdin
    * `:stdout` - A `Wasmex.Pipe` to use as stdout
    * `:stderr` - A `Wasmex.Pipe` to use as stderr

  ## Example

      iex> {:ok, stdin} = Wasmex.Pipe.create()
      iex> Wasmex.Store.new_wasi(%WasiOptions{
      ...>   args: ["first param", "second param"],
      ...>   env: %{"env_key" => "env_value"},
      ...>   preopen: [
      ...>     %Wasmex.Wasi.PreopenOptions{path: "/tmp"}
      ...>   ],
      ...>   stdin: stdin,
      ...> })
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
