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
      calculator: %{
        bytes: calculator_wasm,
        links: %{
          utils: %{bytes: utils_wasm}
        }
      }
    }

    {:ok, pid} = Wasmex.start_link(%{bytes: main_wasm, links: links})

    assert Wasmex.call_function(pid, "calc_seq", [1, 5]) == {:ok, [15]}
  end

  test "linking multiple compiled modules to satisfy dependencies" do
    main_wasm = File.read!(TestHelper.wasm_link_dep_test_file_path())
    calculator_wasm = File.read!(TestHelper.wasm_link_test_file_path())
    utils_wasm = File.read!(TestHelper.wasm_test_file_path())

    {:ok, store} = Wasmex.Store.new()
    {:ok, utils_module} = Wasmex.Module.compile(store, utils_wasm)
    {:ok, calculator_module} = Wasmex.Module.compile(store, calculator_wasm)
    {:ok, main_module} = Wasmex.Module.compile(store, main_wasm)

    links = %{
      calculator: %{
        module: calculator_module,
        links: %{
          utils: %{module: utils_module}
        }
      }
    }

    {:ok, pid} = Wasmex.start_link(%{module: main_module, links: links, store: store})

    assert Wasmex.call_function(pid, "calc_seq", [1, 5]) == {:ok, [15]}
  end

  test "linking wasm modules with imports" do
    calculator_wasm = File.read!(TestHelper.wasm_link_test_file_path())
    utils_wasm = File.read!(TestHelper.wasm_link_import_test_file_path())

    imports = %{
      env: %{
        imported_sum: {:fn, [:i32, :i32], [:i32], fn _context, a, b -> a + b end}
      }
    }

    links = %{utils: %{bytes: utils_wasm}}
    {:ok, pid} = Wasmex.start_link(%{bytes: calculator_wasm, links: links, imports: imports})

    assert Wasmex.call_function(pid, "sum_range", [1, 5]) == {:ok, [15]}
  end

  test "nested sibling links preserve order and the last occurrence of each module name" do
    {:ok, store} = Wasmex.Store.new()

    [main, first_shared, left, left_shared, leaf, right, right_shared] =
      Enum.map(1..7, fn _ ->
        {:ok, module} = Wasmex.Module.compile(store, "(module)")
        module
      end)

    links = [
      shared: %{module: first_shared},
      left: %{
        module: left,
        links: [shared: %{module: left_shared}, leaf: %{module: leaf}]
      },
      right: %{module: right, links: [shared: %{module: right_shared}]}
    ]

    {:ok, pid} = Wasmex.start_link(%{module: main, store: store, links: links})

    assert :sys.get_state(pid).links == [
             %{name: "shared", module: right_shared},
             %{name: "right", module: right},
             %{name: "leaf", module: leaf},
             %{name: "left", module: left}
           ]
  end

  test "deep duplicate links take work proportional to their number" do
    {:ok, store} = Wasmex.Store.new()
    {:ok, module} = Wasmex.Module.compile(store, "(module)")

    reductions =
      Enum.map([2_000, 8_000], fn depth ->
        links =
          Enum.reduce(1..depth, %{}, fn _, children ->
            %{shared: %{module: module, links: children}}
          end)

        :erlang.garbage_collect()
        {:reductions, before} = Process.info(self(), :reductions)
        {:ok, pid} = Wasmex.start_link(%{module: module, store: store, links: links})
        {:reductions, after_count} = Process.info(self(), :reductions)

        assert :sys.get_state(pid).links == [%{name: "shared", module: module}]
        GenServer.stop(pid)
        after_count - before
      end)

    [small, large] = reductions
    # Four times as many links allows GC variance, but rejects quadratic copying.
    assert large < small * 6
  end
end
