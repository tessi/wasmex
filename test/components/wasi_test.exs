defmodule Wasmex.Components.WasiTest do
  use ExUnit.Case, async: true

  alias Wasmex.Wasi.WasiP2Options

  test "outbound http call" do
    component_bytes = File.read!("test/component_fixtures/wasi_p2_test/wasi-p2-test.wasm")

    instance =
      start_supervised!(
        {Wasmex.Components,
         bytes: component_bytes, wasi: %WasiP2Options{inherit_stdout: true, allow_http: true}}
      )

    assert {:ok, time} =
             Wasmex.Components.call_function(instance, "get-time", [])

    assert time =~ Date.utc_today() |> Date.to_iso8601()
  end
end
