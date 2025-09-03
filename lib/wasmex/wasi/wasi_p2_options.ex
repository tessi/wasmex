defmodule Wasmex.Wasi.WasiP2Options do
  @moduledoc ~S"""
  Configures WASI P2 support for a Wasmex.Components.Store.

  WASI (WebAssembly System Interface) P2 provides system interface capabilities
  to WebAssembly components, allowing them to interact with the host system in a
  controlled manner.

  ## Options

    * `:inherit_stdin` - When `true`, allows the component to read from standard input.
      Defaults to `true`.

    * `:inherit_stdout` - When `true`, allows the component to write to standard output.
      Defaults to `true`.

    * `:inherit_stderr` - When `true`, allows the component to write to standard error.
      Defaults to `true`.

    * `:allow_http` - When `true`, enables HTTP capabilities for the component.
      Defaults to `false`.

    * `:allow_filesystem` - When `true`, enables filesystem access for the component.
      Defaults to `true` for backward compatibility.

    * `:preopen_dirs` - List of directories to preopen for filesystem access.
      Defaults to `nil`. Example: `["/tmp", "/home/user/data"]`.

    * `:args` - List of command-line arguments to pass to the component.
      Defaults to `[]`.

    * `:env` - Map of environment variables to make available to the component.
      Defaults to `%{}`.

  ## Example

      iex> wasi_opts = %Wasmex.Wasi.WasiP2Options{
      ...>   args: ["--verbose"],
      ...>   env: %{"DEBUG" => "1"},
      ...>   allow_http: true,
      ...>   allow_filesystem: true,
      ...>   preopen_dirs: ["/tmp", "/data"]
      ...> }
      iex> {:ok, pid} = Wasmex.Components.start_link(%{
      ...>   path: "my_component.wasm",
      ...>   wasi: wasi_opts
      ...> })

  """

  defstruct inherit_stdin: true,
            inherit_stdout: true,
            inherit_stderr: true,
            allow_http: false,
            allow_filesystem: nil,
            preopen_dirs: nil,
            args: [],
            env: %{}

  @type t :: %__MODULE__{
          args: [String.t()],
          env: %{String.t() => String.t()},
          inherit_stdin: boolean(),
          inherit_stdout: boolean(),
          inherit_stderr: boolean(),
          allow_http: boolean(),
          allow_filesystem: boolean() | nil,
          preopen_dirs: [String.t()] | nil
        }
end
