defmodule TestHelper do
  @fixture_project_dir "#{Path.dirname(__ENV__.file)}/fixture_projects"
  @component_type_conversions_source_dir "#{@fixture_project_dir}/component_type_conversions"
  @component_exported_interface_source_dir "#{@fixture_project_dir}/component_exported_interface"
  @counter_resource_component_source_dir "#{@fixture_project_dir}/counter_resource_component"
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

  def counter_resource_component_file_path,
    do:
      "#{@counter_resource_component_source_dir}/target/wasm32-wasip2/release/counter_resource_component.wasm"

  def counter_resource_component_wit_path,
    do: "#{@counter_resource_component_source_dir}/wit/world.wit"

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

  def precompile_wasm_files do
    [
      @wasm_test_source_dir,
      @wasm_import_test_source_dir,
      @wasm_link_import_test_source_dir,
      @wasi_test_source_dir
    ]
    |> Enum.each(fn dir ->
      {_, 0} = System.cmd("cargo", ["build"], cd: dir, stderr_to_stdout: true, parallelism: true)
    end)

    [
      @component_type_conversions_source_dir,
      @component_exported_interface_source_dir
    ]
    |> Enum.each(fn dir ->
      {_, 0} =
        System.cmd("cargo", ["component", "build"],
          cd: dir,
          stderr_to_stdout: true,
          parallelism: true
        )
    end)

    [
      @counter_resource_component_source_dir
    ]
    |> Enum.each(fn dir ->
      {_, 0} =
        System.cmd("cargo", ["build", "--target=wasm32-wasip2", "--release"],
          cd: dir,
          stderr_to_stdout: true,
          parallelism: true
        )
    end)

    {_, 0} =
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
        stderr_to_stdout: true
      )

    {_, 0} =
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
        stderr_to_stdout: true
      )
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

TestHelper.precompile_wasm_files()
ExUnit.start()
