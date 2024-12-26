defmodule Wasmex.Components.ImportTest do
  use ExUnit.Case
  alias Wasmex.Components.FunctionServer
  alias Wasmex.Wasi.WasiP2Options

  test "import functions" do
    component_bytes = File.read!("test/component_fixtures/importer/importer.wasm")
    imports = %{"get-secret-word" => {:fn, fn param -> "buffalo #{param}" end}}
    function_server_pid = start_supervised!(FunctionServer)

    component_pid =
      start_supervised!(
        {Wasmex.Components,
         bytes: component_bytes,
         wasi: %WasiP2Options{inherit_stdout: true},
         imports: %{server_pid: function_server_pid, functions: imports}}
      )

    assert {:ok, "buffalo 7"} =
             Wasmex.Components.call_function(component_pid, "reveal-secret-word", [7])
  end
end
