defmodule Wasm.Components.ComponentTypesTest do
  use ExUnit.Case, async: true

  alias Wasmex.Wasi.WasiP2Options

  setup do
    component_bytes = File.read!("test/component_fixtures/component_types/component_types.wasm")
    instance = start_supervised!({Wasmex.Components, bytes: component_bytes})
    [instance: instance]
  end

  test "strings", %{instance: instance} do
    assert {:ok, "mom"} = Wasmex.Components.call_function(instance, "id-string", ["mom"])
  end

  test "boolean", %{instance: instance} do
    assert {:ok, true} = Wasmex.Components.call_function(instance, "id-bool", [true])
  end

  test "integers", %{instance: instance} do
    # all the integer types
    for type <- ["u8", "u16", "u32", "u64", "s8", "s16", "s32", "s64"] do
      assert {:ok, 7} = Wasmex.Components.call_function(instance, "id-#{type}", [7])
    end
  end

  test "floats", %{instance: instance} do
    pi = 3.14592
    assert {:ok, pi_result} = Wasmex.Components.call_function(instance, "id-f32", [pi])
    assert_in_delta(pi, pi_result, 1.0e-5)
    assert {:ok, pi_result} = Wasmex.Components.call_function(instance, "id-f64", [pi])
    assert_in_delta(pi, pi_result, 1.0e-5)
  end

  test "records", %{instance: instance} do
    assert {:ok, %{x: 1, y: 2}} =
             Wasmex.Components.call_function(instance, "id-record", [
               %{"x" => 1, "y" => 2}
             ])

    assert {:ok, %{x: 1, y: 2}} =
             Wasmex.Components.call_function(instance, "id-record", [
               %{x: 1, y: 2}
             ])
  end

  test "record with kebab-field" do
    component_bytes = File.read!("test/component_fixtures/hello_world/hello_world.wasm")

    instance =
      start_supervised!(
        {HelloWorld, bytes: component_bytes, wasi: %WasiP2Options{allow_http: true}}
      )

    assert {:ok, %{kebab_field: "foo"}} =
             Wasmex.Components.call_function(instance, "echo-kebab", [
               %{kebab_field: "foo"}
             ])
  end

  test "lists", %{instance: instance} do
    assert {:ok, [1, 2, 3]} =
             Wasmex.Components.call_function(instance, "id-list", [[1, 2, 3]])
  end

  test "tuples", %{instance: instance} do
    assert {:ok, {1, "two"}} =
             Wasmex.Components.call_function(instance, "id-tuple", [{1, "two"}])
  end

  test "option types", %{instance: instance} do
    assert {:ok, 7} = Wasmex.Components.call_function(instance, "id-option", [7])
    assert {:ok, nil} = Wasmex.Components.call_function(instance, "id-option", [nil])
  end

  test "enums", %{instance: instance} do
    assert {:error, message} = Wasmex.Components.call_function(instance, "id-enum", [:foo])
    assert message =~ "Enum value not found: foo"
    assert {:ok, :s} = Wasmex.Components.call_function(instance, "id-enum", [:s])
  end

  test "results", %{instance: instance} do
    assert {:ok, {:ok, 7}} = Wasmex.Components.call_function(instance, "id-result", [{:ok, 7}])

    assert {:ok, {:error, 3}} =
             Wasmex.Components.call_function(instance, "id-result", [{:error, 3}])
  end

  test "variant", %{instance: instance} do
    assert {:ok, :all} = Wasmex.Components.call_function(instance, "id-variant", [:all])
    assert {:ok, :none} = Wasmex.Components.call_function(instance, "id-variant", [:none])
    assert {:ok, {:lt, 7}} = Wasmex.Components.call_function(instance, "id-variant", [{:lt, 7}])
  end

  test "flags", %{instance: instance} do
    # Test with all flags set
    assert {:ok, %{read: true, write: true, exec: true}} =
             Wasmex.Components.call_function(instance, "id-flags", [
               %{read: true, write: true, exec: true}
             ])

    # Test with some flags set - note that in the result, only the true flags are included
    assert {:ok, %{read: true, exec: true}} =
             Wasmex.Components.call_function(instance, "id-flags", [
               %{read: true, write: false, exec: true}
             ])

    # Test with no flags set
    assert {:ok, %{}} =
             Wasmex.Components.call_function(instance, "id-flags", [%{}])
  end

  test "char", %{instance: instance} do
    # Test with a Unicode character passed as a string
    assert {:ok, "A"} = Wasmex.Components.call_function(instance, "id-char", ["A"])

    # Test with a Unicode character from an integer code point
    assert {:ok, "Ω"} = Wasmex.Components.call_function(instance, "id-char", [937])

    # Test with an emoji
    assert {:ok, "🚀"} = Wasmex.Components.call_function(instance, "id-char", ["🚀"])
  end
end
