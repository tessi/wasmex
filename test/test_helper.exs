defmodule TestHelper do
  @wasm_source_dir "#{Path.dirname(__ENV__.file)}/wasm_source"

  def wasm_file_path,
    do: "#{@wasm_source_dir}/target/wasm32-unknown-unknown/debug/wasmex_test.wasm"

  def compile_wasm_file do
    {"", 0} = System.cmd("cargo", ["build"], cd: @wasm_source_dir)
  end
end

TestHelper.compile_wasm_file()
ExUnit.start()
