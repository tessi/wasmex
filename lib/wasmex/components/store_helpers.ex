defmodule Wasmex.Components.StoreHelpers do
  @moduledoc """
  Helper functions for creating stores with specific configurations,
  particularly for filesystem access.
  """

  alias Wasmex.Wasi.WasiP2Options
  alias Wasmex.Components.Store

  @doc """
  Creates a new WASI-enabled store with filesystem access configured for the given sandbox directory.

  Maps sandbox subdirectories to WASM paths:
  - `sandbox_dir/input` -> Available in WASM as `/input`
  - `sandbox_dir/output` -> Available in WASM as `/output`
  - `sandbox_dir/work` -> Available in WASM as `/work`

  ## Example

      sandbox_dir = Wasmex.Test.FilesystemSandbox.setup()
      {:ok, store} = Wasmex.Components.StoreHelpers.new_wasi_with_fs(sandbox_dir)
  """
  def new_wasi_with_fs(sandbox_dir, opts \\ %{}) do
    # Build list of directories to preopen
    preopen_dirs = [
      Path.join(sandbox_dir, "input"),
      Path.join(sandbox_dir, "output"),
      Path.join(sandbox_dir, "work")
    ]

    wasi_opts = %WasiP2Options{
      preopen_dirs: preopen_dirs,
      inherit_stdout: Map.get(opts, :inherit_stdout, true),
      inherit_stderr: Map.get(opts, :inherit_stderr, true),
      allow_filesystem: true,
      args: Map.get(opts, :args, []),
      env: Map.get(opts, :env, %{})
    }

    Store.new_wasi(wasi_opts, Map.get(opts, :store_limits))
  end
end
