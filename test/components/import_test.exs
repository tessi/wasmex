defmodule Wasmex.Components.ImportTest do
  use ExUnit.Case
  alias Wasmex.Components.FunctionServer
  alias Wasmex.Wasi.WasiP2Options

  test "import functions" do
    component_bytes = File.read!("test/component_fixtures/importer/importer.wasm")

    imports = %{
      "get-secret-word" => {:fn, fn param1, param2 -> "#{param1} #{param2}" end},
      "get-number" => {:fn, fn -> 42 end},
      "get-list" => {:fn, fn -> ["hi", "there"] end},
      "get-point" => {:fn, fn -> %{x: 1, y: 2} end}
    }

    component_pid =
      start_supervised!(
        {Wasmex.Components,
         bytes: component_bytes, wasi: %WasiP2Options{inherit_stdout: true}, imports: imports}
      )

    assert {:ok, "7 foo 42 hi,there x: 1 y: 2"} =
             Wasmex.Components.call_function(component_pid, "reveal-secret-word", [7])
  end
end
