defmodule Wasmex.Wasi.WasiP2Options do
  @moduledoc ~S"""
  Configures WASI P2 support for a Wasmex.ComponentStore.

  """

  defstruct inherit_stdin: true,
            inherit_stdout: true,
            inherit_stderr: true,
            allow_http: false,
            args: [],
            env: %{}

  @type t :: %__MODULE__{
          args: [String.t()],
          env: %{String.t() => String.t()},
          inherit_stdin: boolean(),
          inherit_stdout: boolean(),
          inherit_stdin: boolean(),
          allow_http: boolean()
        }
end
