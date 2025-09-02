defmodule TestHelper do
  @fixture_project_dir "#{Path.dirname(__ENV__.file)}/fixture_projects"
  @component_type_conversions_source_dir "#{@fixture_project_dir}/component_type_conversions"
  @component_exported_interface_source_dir "#{@fixture_project_dir}/component_exported_interface"
  @wasm_test_source_dir "#{@fixture_project_dir}/wasm_test"
  @wasm_link_test_source_dir "#{@fixture_project_dir}/wasm_link_test"
  @wasm_link_dep_test_source_dir "#{@fixture_project_dir}/wasm_link_dep_test"
  @wasm_link_import_test_source_dir "#{@fixture_project_dir}/wasm_link_import_test"
  @wasm_import_test_source_dir "#{@fixture_project_dir}/wasm_import_test"
  @wasi_test_source_dir "#{@fixture_project_dir}/wasi_test"

  def component_type_conversions_file_path,
    do:
      "#{@component_type_conversions_source_dir}/target/wasm32-wasip1/debug/component_type_conversions.wasm"

  def component_exported_interface_file_path,
    do:
      "#{@component_exported_interface_source_dir}/target/wasm32-wasip1/debug/exported_interface.wasm"

  def wasm_test_file_path,
    do: "#{@wasm_test_source_dir}/target/wasm32-unknown-unknown/debug/wasmex_test.wasm"

  def wasm_link_test_file_path,
    do: "#{@wasm_link_test_source_dir}/target/wasm32-unknown-unknown/debug/wasmex_link_test.wasm"

  def wasm_link_dep_test_file_path,
    do:
      "#{@wasm_link_dep_test_source_dir}/target/wasm32-unknown-unknown/debug/wasmex_link_dep_test.wasm"

  def wasm_link_import_test_file_path,
    do:
      "#{@wasm_link_import_test_source_dir}/target/wasm32-unknown-unknown/debug/wasmex_link_import_test.wasm"

  def wasm_import_test_file_path,
    do: "#{@wasm_import_test_source_dir}/target/wasm32-unknown-unknown/debug/wasmex_test.wasm"

  def wasi_test_file_path,
    do: "#{@wasi_test_source_dir}/target/wasm32-wasip1/debug/main.wasm"

  def get_wasmtime_version do
    # Read wasmtime version from Cargo.toml
    cargo_toml = File.read!("native/wasmex/Cargo.toml")

    case Regex.run(~r/wasmtime\s*=\s*"([^"]+)"/, cargo_toml) do
      [_, version] -> version
      _ -> raise "Could not find wasmtime version in Cargo.toml"
    end
  end

  def ensure_wasi_adapter do
    # Download WASI adapter from wasmtime release if it doesn't exist
    adapter_path = "test/component_fixtures/wasi_snapshot_preview1.reactor.wasm"

    unless File.exists?(adapter_path) do
      version = get_wasmtime_version()
      IO.puts("Downloading WASI adapter from wasmtime v#{version}...")

      url =
        "https://github.com/bytecodealliance/wasmtime/releases/download/v#{version}/wasi_snapshot_preview1.reactor.wasm"

      {output, exit_code} =
        System.cmd("curl", ["-L", "-o", adapter_path, url], stderr_to_stdout: true)

      if exit_code != 0 do
        IO.puts("Failed to download WASI adapter: #{output}")
        raise "Failed to download WASI adapter. Please ensure curl is installed."
      end

      IO.puts("WASI adapter downloaded successfully.")
    end
  end

  def precompile_wasm_files do
    # Ensure WASI adapter is available
    ensure_wasi_adapter()

    # Suppress cargo output by collecting into a list (discarded)
    {_output, 0} =
      System.cmd("cargo", ["build"], cd: @wasm_test_source_dir, stderr_to_stdout: true, into: [])

    {_output, 0} =
      System.cmd("cargo", ["build"],
        cd: @wasm_import_test_source_dir,
        stderr_to_stdout: true,
        into: []
      )

    {_output, 0} =
      System.cmd("cargo", ["build"],
        cd: @wasm_link_import_test_source_dir,
        stderr_to_stdout: true,
        into: []
      )

    {_output, 0} =
      System.cmd("cargo", ["build"], cd: @wasi_test_source_dir, stderr_to_stdout: true, into: [])

    {_output, 0} =
      System.cmd(
        "cargo",
        [
          "rustc",
          "--target=wasm32-unknown-unknown",
          "--",
          "--extern",
          "utils=#{@wasm_test_source_dir}/target/wasm32-unknown-unknown/debug/wasmex_test.wasm"
        ],
        cd: @wasm_link_test_source_dir,
        stderr_to_stdout: true,
        into: []
      )

    {_output, 0} =
      System.cmd(
        "cargo",
        [
          "rustc",
          "--target=wasm32-unknown-unknown",
          "--",
          "--extern",
          "calculator=#{@wasm_link_test_source_dir}/target/wasm32-unknown-unknown/debug/wasmex_link_test.wasm"
        ],
        cd: @wasm_link_dep_test_source_dir,
        stderr_to_stdout: true,
        into: []
      )

    {_output, 0} =
      System.cmd("cargo", ["component", "build"],
        cd: @component_type_conversions_source_dir,
        stderr_to_stdout: true,
        into: []
      )

    {_output, 0} =
      System.cmd("cargo", ["component", "build"],
        cd: @component_exported_interface_source_dir,
        stderr_to_stdout: true,
        into: []
      )

    # Build new component fixtures
    component_fixtures_dir = "#{Path.dirname(__ENV__.file)}/component_fixtures"

    # Build counter-component
    counter_dir = "#{component_fixtures_dir}/counter-component"

    if File.exists?(counter_dir) do
      {_output, _code} =
        System.cmd("sh", ["build.sh"], cd: counter_dir, stderr_to_stdout: true, into: [])
    end

    # Build filesystem-component
    filesystem_dir = "#{component_fixtures_dir}/filesystem-component"

    if File.exists?(filesystem_dir) do
      {_output, _code} =
        System.cmd("sh", ["build.sh"], cd: filesystem_dir, stderr_to_stdout: true, into: [])
    end

    # Build wasi-test-component
    wasi_test_dir = "#{component_fixtures_dir}/wasi-test-component"

    if File.exists?(wasi_test_dir) do
      {_output, _code} =
        System.cmd("sh", ["build.sh"], cd: wasi_test_dir, stderr_to_stdout: true, into: [])
    end
  end

  def wasm_module do
    {:ok, store} = Wasmex.Store.new()

    {:ok, wasm_module} =
      Wasmex.Module.compile(store, File.read!(TestHelper.wasm_test_file_path()))

    %{store: store, module: wasm_module}
  end

  def wasm_link_module do
    {:ok, store} = Wasmex.Store.new()

    {:ok, wasm_module} =
      Wasmex.Module.compile(store, File.read!(TestHelper.wasm_link_test_file_path()))

    %{store: store, module: wasm_module}
  end

  def wasm_link_dep_module do
    {:ok, store} = Wasmex.Store.new()

    {:ok, wasm_module} =
      Wasmex.Module.compile(store, File.read!(TestHelper.wasm_link_dep_test_file_path()))

    %{store: store, module: wasm_module}
  end

  def wasm_link_import_module do
    {:ok, store} = Wasmex.Store.new()

    {:ok, wasm_module} =
      Wasmex.Module.compile(store, File.read!(TestHelper.wasm_link_import_test_file_path()))

    %{store: store, module: wasm_module}
  end

  def wasm_import_module do
    {:ok, store} = Wasmex.Store.new()

    {:ok, wasm_module} =
      Wasmex.Module.compile(store, File.read!(TestHelper.wasm_import_test_file_path()))

    %{store: store, module: wasm_module}
  end

  def default_imported_functions_env do
    %{
      imported_sum3: {:fn, [:i32, :i32, :i32], [:i32], fn _context, a, b, c -> a + b + c end},
      imported_sumf: {:fn, [:f32, :f32], [:f32], fn _context, a, b -> a + b end},
      imported_void: {:fn, [], [], fn _context -> nil end}
    }
  end

  def default_imported_functions_env_stringified do
    default_imported_functions_env()
    |> Enum.map(fn {k, v} -> {to_string(k), v} end)
    |> Enum.into(%{})
  end

  def component_type_conversions_import_map do
    ~w(
      string u8 u16 u32 u64 s8 s16 s32 s64 f32 f64 bool char variant enum option-u8
      result-u8-string result-u8-none result-none-string result-none-none
      list-u8 tuple-u8-string flags point record-complex
    )
    |> Enum.map(fn id -> {"import-id-#{id}", {:fn, & &1}} end)
    |> Enum.into(%{})
  end

  @doc ~S"""
  Inspects an expression in a test.

  Useful for test descriptions to make sure the tested function exists and is displayed nicely in test output.
  """
  defmacro t(expr) do
    quote do
      inspect(unquote(expr))
    end
  end
end

# Configure Logger for tests to suppress debug output
Logger.configure(level: :warning)

TestHelper.precompile_wasm_files()
ExUnit.start()
