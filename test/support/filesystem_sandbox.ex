defmodule Wasmex.Test.FilesystemSandbox do
  @moduledoc """
  Manages temporary sandboxed directories for WASI filesystem tests.
  Each test gets an isolated directory that's cleaned up after.
  """

  def setup do
    # Create unique sandbox per test
    test_id = :erlang.unique_integer([:positive])
    sandbox_dir = Path.join(System.tmp_dir!(), "wasmex_test_#{test_id}")
    File.mkdir_p!(sandbox_dir)

    # Create predictable structure
    File.mkdir_p!(Path.join(sandbox_dir, "input"))
    File.mkdir_p!(Path.join(sandbox_dir, "output"))
    File.mkdir_p!(Path.join(sandbox_dir, "work"))

    # Pre-populate input dir with test files
    File.write!(Path.join(sandbox_dir, "input/readme.txt"), "Test file content")
    File.write!(Path.join(sandbox_dir, "input/data.json"), ~s({"test": true}))

    sandbox_dir
  end

  def cleanup(sandbox_dir) do
    File.rm_rf!(sandbox_dir)
  end
end
