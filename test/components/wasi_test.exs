defmodule Wasmex.Components.WasiTest do
  use ExUnit.Case, async: true

  alias Wasmex.Wasi.WasiP2Options

  test "outbound http call" do
    {:ok, store} =
      Wasmex.Components.Store.new_wasi(%WasiP2Options{inherit_stdout: true, allow_http: true})

    component_bytes = File.read!("test/component_fixtures/wasi_p2_test/wasi-p2-test.wasm")
    {:ok, component} = Wasmex.Components.Component.new(store, component_bytes)
    {:ok, instance} = Wasmex.Components.Instance.new(store, component)

    assert {:ok, time} =
             Wasmex.Components.Instance.call_function(instance, "get-time", [])

    assert time =~ Date.utc_today() |> Date.to_iso8601()
  end
end
