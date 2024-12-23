defmodule Wasmex.Components.ImportTest do
  use ExUnit.Case

  alias Wasmex.Wasi.WasiP2Options

  test "import functions" do
    {:ok, store} =
      Wasmex.Components.Store.new_wasi(%WasiP2Options{inherit_stdout: true})

    component_bytes = File.read!("test/component_fixtures/importer/importer.wasm")
    {:ok, component} = Wasmex.Components.Component.new(store, component_bytes)
    {:ok, instance} = Wasmex.Components.Instance.new(store, component, %{"get-secret-work" => fn param -> "buffalo #{param}" end})

    assert {:ok, "buffalo 7"} =
             Wasmex.Components.Instance.call_function(instance, "reveal-secret-word", [7])
  end
end
