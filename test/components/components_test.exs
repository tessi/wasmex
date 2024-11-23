defmodule Wasmex.ComponentsTest do
  use ExUnit.Case, async: true

  test "interacting with a component server" do
    component_bytes = File.read!("test/component_fixtures/component_types/component_types.wasm")
    component = start_supervised!({Wasmex.Components, %{bytes: component_bytes}})
    assert {:ok, "mom"} = Wasmex.Components.call_function(component, "id-string", ["mom"])
  end
end
