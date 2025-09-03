defmodule Mix.Tasks.Wasmex.BuildFixtures do
  @moduledoc """
  Builds WebAssembly component fixtures for testing.

  This task builds all the Rust-based WebAssembly components in the
  test/component_fixtures directory that are required for running tests.

  ## Usage

      mix wasmex.build_fixtures

  This task is automatically run before tests via the mix alias.
  """
  use Mix.Task

  @shortdoc "Build WebAssembly component fixtures for testing"

  @fixtures [
    "counter-component",
    "filesystem-component",
    "wasi-test-component"
  ]

  def run(_args) do
    ensure_tools_installed()
    build_fixtures()
  end

  defp ensure_tools_installed do
    unless System.find_executable("cargo") do
      Mix.raise("cargo not found. Please install Rust: https://rustup.rs/")
    end

    # Check if cargo-component is installed
    case System.cmd("cargo", ["component", "--version"], stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      _ ->
        Mix.shell().info("cargo-component not found. Installing...")
        {_, 0} = System.cmd("cargo", ["install", "--locked", "cargo-component"])
        Mix.shell().info("cargo-component installed successfully.")
    end

    # Ensure wasm32 targets are installed
    ensure_target_installed("wasm32-unknown-unknown")
    ensure_target_installed("wasm32-wasip1")
    ensure_target_installed("wasm32-wasip2")
  end

  defp ensure_target_installed(target) do
    case System.cmd("rustup", ["target", "list", "--installed"], stderr_to_stdout: true) do
      {output, 0} ->
        if not String.contains?(output, target) do
          Mix.shell().info("Installing Rust target: #{target}")
          {_, 0} = System.cmd("rustup", ["target", "add", target])
        end

      _ ->
        Mix.raise("rustup not found. Please ensure Rust is properly installed.")
    end
  end

  defp build_fixtures do
    fixtures_dir = Path.join(File.cwd!(), "test/component_fixtures")

    Enum.each(@fixtures, fn fixture ->
      build_fixture(fixtures_dir, fixture)
    end)
  end

  defp build_fixture(fixtures_dir, fixture) do
    fixture_path = Path.join(fixtures_dir, fixture)

    wasm_path =
      Path.join([
        fixture_path,
        "target",
        "wasm32-wasip1",
        "release",
        "#{String.replace(fixture, "-", "_")}.wasm"
      ])

    if File.exists?(fixture_path) do
      build_if_needed(fixture_path, wasm_path, fixture)
    else
      Mix.shell().error("Warning: Component fixture not found: #{fixture_path}")
    end
  end

  defp build_if_needed(fixture_path, wasm_path, fixture) do
    should_build =
      not File.exists?(wasm_path) or source_newer_than_target?(fixture_path, wasm_path)

    if should_build do
      run_build_command(fixture_path, fixture)
    end
  end

  defp run_build_command(fixture_path, fixture) do
    case System.cmd("cargo", ["component", "build", "--release"],
           cd: fixture_path,
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        :ok

      {output, _} ->
        Mix.raise("Failed to build #{fixture}:\n#{output}")
    end
  end

  defp source_newer_than_target?(source_dir, target_file) do
    case File.stat(target_file) do
      {:ok, %{mtime: target_mtime}} ->
        any_source_newer?(source_dir, target_mtime)

      _ ->
        # Target doesn't exist, so we need to build
        true
    end
  end

  defp any_source_newer?(source_dir, target_mtime) do
    Path.wildcard(Path.join(source_dir, "**/*.{rs,toml,wit}"))
    |> Enum.any?(&source_file_newer?(&1, target_mtime))
  end

  defp source_file_newer?(source_file, target_mtime) do
    case File.stat(source_file) do
      {:ok, %{mtime: source_mtime}} ->
        source_mtime > target_mtime

      _ ->
        false
    end
  end
end
