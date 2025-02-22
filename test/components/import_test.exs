defmodule Wasmex.Components.ImportTest do
  use ExUnit.Case
  alias Wasmex.Wasi.WasiP2Options

  test "import functions" do
    component_bytes = File.read!("test/component_fixtures/importer/importer.wasm")

    imports = %{
      "get-secret-word" => {:fn, fn param1, param2 -> "#{param1} #{param2}" end},
      "get-number" => {:fn, fn -> 42 end},
      "get-list" => {:fn, fn -> ["hi", "there"] end},
      "get-point" => {:fn, fn -> %{x: 1, y: 2} end},
      "get-tuple" => {:fn, fn -> {1, "foo"} end},
      "print" => {:fn, fn x -> IO.puts(x) end}
    }

    component_pid =
      start_supervised!(
        {Wasmex.Components,
         bytes: component_bytes,
         wasi: %WasiP2Options{inherit_stdout: true, allow_http: true},
         imports: imports}
      )

    assert {:ok, "7 foo 42 hi,there x: 1 y: 2"} =
             Wasmex.Components.call_function(component_pid, "reveal-secret-word", [7])

    assert {:ok, "1 foo"} =
             Wasmex.Components.call_function(component_pid, "show-tuple", [])

    assert {:ok, _} = Wasmex.Components.call_function(component_pid, "print-secret-word", [])

    assert {:ok, {:ok, "bananas"}} =
             Wasmex.Components.call_function(component_pid, "print-or-error", ["bananas"])

    assert {:ok, {:error, "error"}} =
             Wasmex.Components.call_function(component_pid, "print-or-error", ["error"])
  end
end
