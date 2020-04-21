defmodule TestHelper do
  @wasm_test_source_dir "#{Path.dirname(__ENV__.file)}/wasm_test"
  @wasm_import_test_source_dir "#{Path.dirname(__ENV__.file)}/wasm_import_test"

  def wasm_test_file_path,
    do: "#{@wasm_test_source_dir}/target/wasm32-unknown-unknown/debug/wasmex_test.wasm"
  
  def wasm_import_test_file_path,
    do: "#{@wasm_import_test_source_dir}/target/wasm32-unknown-unknown/debug/wasmex_test.wasm"

  def compile_wasm_files do
    {"", 0} = System.cmd("cargo", ["build"], cd: @wasm_test_source_dir)
    {"", 0} = System.cmd("cargo", ["build"], cd: @wasm_import_test_source_dir)
  end
end

TestHelper.compile_wasm_files()
ExUnit.start()
