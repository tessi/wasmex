defmodule Wasm.Components.ComponentTypesTest do
  use ExUnit.Case, async: true

  alias Wasmex.Wasi.WasiP2Options

  setup do
    {:ok, store} = Wasmex.Components.Store.new()
    component_bytes = File.read!("test/component_fixtures/component_types/component_types.wasm")
    {:ok, component} = Wasmex.Components.Component.new(store, component_bytes)
    {:ok, instance} = Wasmex.Components.Instance.new(store, component)
    [instance: instance]
  end

  test "strings", %{instance: instance} do
    assert {:ok, "mom"} = Wasmex.Components.Instance.call_function(instance, "id-string", ["mom"])
  end

  test "boolean", %{instance: instance} do
    assert {:ok, true} = Wasmex.Components.Instance.call_function(instance, "id-bool", [true])
  end

  test "integers", %{instance: instance} do
    # all the integer types
    for type <- ["u8", "u16", "u32", "u64", "s8", "s16", "s32", "s64"] do
      assert {:ok, 7} = Wasmex.Components.Instance.call_function(instance, "id-#{type}", [7])
    end
  end

  test "floats", %{instance: instance} do
    pi = 3.14592
    assert {:ok, pi_result} = Wasmex.Components.Instance.call_function(instance, "id-f32", [pi])
    assert_in_delta(pi, pi_result, 1.0e-5)
    assert {:ok, pi_result} = Wasmex.Components.Instance.call_function(instance, "id-f64", [pi])
    assert_in_delta(pi, pi_result, 1.0e-5)
  end

  test "records", %{instance: instance} do
    assert {:ok, %{x: 1, y: 2}} =
             Wasmex.Components.Instance.call_function(instance, "id-record", [
               %{"x" => 1, "y" => 2}
             ])

    assert {:ok, %{x: 1, y: 2}} =
             Wasmex.Components.Instance.call_function(instance, "id-record", [
               %{x: 1, y: 2}
             ])
  end

  test "record with kebab-field" do
    {:ok, store} = Wasmex.Components.Store.new_wasi(%WasiP2Options{})
    component_bytes = File.read!("test/component_fixtures/hello_world/hello_world.wasm")
    {:ok, component} = Wasmex.Components.Component.new(store, component_bytes)
    {:ok, instance} = Wasmex.Components.Instance.new(store, component)

    assert {:ok, %{kebab_field: "foo"}} =
             Wasmex.Components.Instance.call_function(instance, "echo-kebab", [
               %{kebab_field: "foo"}
             ])
  end

  test "lists", %{instance: instance} do
    assert {:ok, [1, 2, 3]} =
             Wasmex.Components.Instance.call_function(instance, "id-list", [[1, 2, 3]])
  end

  test "tuples", %{instance: instance} do
    assert {:ok, {1, "two"}} =
             Wasmex.Components.Instance.call_function(instance, "id-tuple", [{1, "two"}])
  end

  test "option types", %{instance: instance} do
    assert {:ok, 7} = Wasmex.Components.Instance.call_function(instance, "id-option", [7])
    assert {:ok, nil} = Wasmex.Components.Instance.call_function(instance, "id-option", [nil])
  end
end
