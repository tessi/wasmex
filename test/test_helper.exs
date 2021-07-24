defmodule TestHelper do
  @ets_table __MODULE__

  @wasm_test_source_dir "#{Path.dirname(__ENV__.file)}/wasm_test"
  @wasm_import_test_source_dir "#{Path.dirname(__ENV__.file)}/wasm_import_test"
  @wasi_test_source_dir "#{Path.dirname(__ENV__.file)}/wasi_test"

  def wasm_test_file_path,
    do: "#{@wasm_test_source_dir}/target/wasm32-unknown-unknown/debug/wasmex_test.wasm"

  def wasm_import_test_file_path,
    do: "#{@wasm_import_test_source_dir}/target/wasm32-unknown-unknown/debug/wasmex_test.wasm"

  def wasi_test_file_path,
    do: "#{@wasi_test_source_dir}/target/wasm32-wasi/debug/main.wasm"

  def precompile_wasm_files do
    {"", 0} = System.cmd("cargo", ["build"], cd: @wasm_test_source_dir)
    {"", 0} = System.cmd("cargo", ["build"], cd: @wasm_import_test_source_dir)
    {"", 0} = System.cmd("cargo", ["build"], cd: @wasi_test_source_dir)

    # cache precompiled modules in an ETS so our tests can re-use them
    :ets.new(@ets_table, [:named_table, read_concurrency: true])

    {:ok, wasm_module} = Wasmex.Module.compile(File.read!(TestHelper.wasm_test_file_path()))
    :ets.insert(@ets_table, {:wasm, wasm_module})

    {:ok, wasm_import_module} =
      Wasmex.Module.compile(File.read!(TestHelper.wasm_import_test_file_path()))

    :ets.insert(@ets_table, {:wasm_import, wasm_import_module})

    {:ok, wasi_module} = Wasmex.Module.compile(File.read!(TestHelper.wasi_test_file_path()))
    :ets.insert(@ets_table, {:wasi, wasi_module})
  end

  def wasm_module, do: :ets.lookup(@ets_table, :wasm) |> Keyword.get(:wasm)
  def wasm_import_module, do: :ets.lookup(@ets_table, :wasm_import) |> Keyword.get(:wasm_import)
  def wasi_module, do: :ets.lookup(@ets_table, :wasi) |> Keyword.get(:wasi)

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
end

TestHelper.precompile_wasm_files()
ExUnit.start()
