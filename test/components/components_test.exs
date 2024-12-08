defmodule Wasmex.ComponentsTest do
  use ExUnit.Case, async: true
  alias Wasmex.Wasi.WasiP2Options

  test "interacting with a component GenServer" do
    component_bytes = File.read!("test/component_fixtures/component_types/component_types.wasm")
    component_pid = start_supervised!({Wasmex.Components, %{bytes: component_bytes}})
    assert {:ok, "mom"} = Wasmex.Components.call_function(component_pid, "id-string", ["mom"])
    assert {:error, _error} = Wasmex.Components.call_function(component_pid, "garbage", ["wut"])
  end

  test "using the component macro" do
    component_bytes = File.read!("test/component_fixtures/hello_world/hello_world.wasm")
    component_pid = start_supervised!({HelloWorld, %{bytes: component_bytes, wasi: %WasiP2Options{}}})
    assert {:ok, "Hello, Elixir!"} = HelloWorld.greet(component_pid, "Elixir")
  end

  test "wasi interaction" do
    component_bytes = File.read!("test/component_fixtures/wasi_p2_test/wasi-p2-test.wasm")

    component_pid =
      start_supervised!(
        {Wasmex.Components, %{bytes: component_bytes, wasi: %WasiP2Options{allow_http: true}}}
      )

    assert {:ok, time} = Wasmex.Components.call_function(component_pid, "get-time", [])

    assert time =~ Date.utc_today() |> Date.to_iso8601()
  end

  test "register by name" do
    component_bytes = File.read!("test/component_fixtures/component_types/component_types.wasm")

    {:ok, _pid} =
      start_supervised({Wasmex.Components, bytes: component_bytes, name: ComponentTypes})

    assert {:ok, "mom"} = Wasmex.Components.call_function(ComponentTypes, "id-string", ["mom"])
  end
end
