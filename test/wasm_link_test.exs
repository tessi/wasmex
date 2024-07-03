defmodule WasmLinkTest do
  use ExUnit.Case, async: true

  alias TestHelper

  test "linking wasm modules using bytes" do
    calculator_wasm = File.read!(TestHelper.wasm_link_test_file_path())
    utils_wasm = File.read!(TestHelper.wasm_test_file_path())

    links = %{utils: %{bytes: utils_wasm}}
    {:ok, pid} = Wasmex.start_link(%{bytes: calculator_wasm, links: links})

    assert Wasmex.call_function(pid, "sum_range", [1, 5]) == {:ok, [15]}
  end

  test "linking wasm modules using compiled module" do
    calculator_wasm = File.read!(TestHelper.wasm_link_test_file_path())
    utils_wasm = File.read!(TestHelper.wasm_test_file_path())

    {:ok, store} = Wasmex.Store.new()
    {:ok, utils_module} = Wasmex.Module.compile(store, utils_wasm)

    links = %{utils: %{module: utils_module}}
    {:ok, pid} = Wasmex.start_link(%{bytes: calculator_wasm, links: links, store: store})

    assert Wasmex.call_function(pid, "sum_range", [1, 5]) == {:ok, [15]}
  end

  test "linking multiple modules to satisfy dependencies" do
    main_wasm = File.read!(TestHelper.wasm_link_dep_test_file_path())
    calculator_wasm = File.read!(TestHelper.wasm_link_test_file_path())
    utils_wasm = File.read!(TestHelper.wasm_test_file_path())

    links = %{
      utils: %{bytes: utils_wasm},
      calculator: %{bytes: calculator_wasm}
    }

    {:ok, pid} = Wasmex.start_link(%{bytes: main_wasm, links: links})

    assert Wasmex.call_function(pid, "calc_seq", [1, 5]) == {:ok, [15]}
  end
end
