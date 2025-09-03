defmodule Wasmex.Components.ServerTest do
  use ExUnit.Case, async: true
  alias Wasmex.Wasi.WasiP2Options

  test "interacting with a component GenServer" do
    component_bytes = File.read!(TestHelper.component_type_conversions_file_path())

    imports =
      TestHelper.component_type_conversions_import_map()
      |> Map.merge(%{"import-id-string" => {:fn, fn _ -> "Polo" end}})

    component_pid =
      start_supervised!({Wasmex.Components, bytes: component_bytes, imports: imports})

    assert {:ok, "Polo"} =
             Wasmex.Components.call_function(component_pid, "export-id-string", ["Marco!"])

    assert {:error, _error} =
             Wasmex.Components.call_function(component_pid, "non-existent-export", ["wut"])
  end

  test "loading a component from a path" do
    component_pid =
      start_supervised!(
        {Wasmex.Components,
         path: TestHelper.component_type_conversions_file_path(),
         imports: TestHelper.component_type_conversions_import_map()}
      )

    assert {:ok, "Echo"} =
             Wasmex.Components.call_function(component_pid, "export-id-string", ["Echo"])
  end

  test "specifying options as a map" do
    component_pid =
      start_supervised!(
        {Wasmex.Components,
         %{
           path: TestHelper.component_type_conversions_file_path(),
           imports: TestHelper.component_type_conversions_import_map()
         }}
      )

    assert {:ok, "Echo"} =
             Wasmex.Components.call_function(component_pid, "export-id-string", ["Echo"])
  end

  test "using the component server macro" do
    component_bytes = File.read!("test/component_fixtures/hello_world/hello_world.wasm")

    component_pid =
      start_supervised!(
        {HelloWorld, bytes: component_bytes, wasi: %WasiP2Options{allow_http: true}}
      )

    assert {:ok, "Hello, Elixir from a function defined in the module!"} =
             HelloWorld.greet(component_pid, "Elixir")

    assert {:ok, [greeting1, greeting2]} =
             HelloWorld.multi_greet(component_pid, "Elixir", 2)

    assert greeting1 =~ "Hello"
    assert greeting2 =~ "Hello"
  end

  test "register by name" do
    component_bytes = File.read!(TestHelper.component_type_conversions_file_path())

    {:ok, _pid} =
      start_supervised(
        {Wasmex.Components,
         bytes: component_bytes,
         name: ComponentTypes,
         imports: TestHelper.component_type_conversions_import_map()}
      )

    assert {:ok, "Echo"} =
             Wasmex.Components.call_function(ComponentTypes, "export-id-string", ["Echo"])
  end
end
