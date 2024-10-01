defmodule Wasmex.WasmComponentsTest do
  use ExUnit.Case, async: true

  alias Wasmex.Engine
  alias Wasmex.EngineConfig

  # setup do
  #   {:ok, store} = Wasmex.Store.new_wasi(%Wasmex.Wasi.WasiOptions{})
  #   component_bytes = File.read!("./todo-list.wasm")
  #   IO.inspect("building component")
  #   {:ok, store} = Wasmex.ComponentStore.new(%Wasmex.Wasi.WasiOptions{})
  #   {:ok, component} = Wasmex.Component.new(store, component_bytes)
  #   %{store: store, component: component}
  # end

  # test "invoke component func", %{store: store, component: component} do
  #   IO.inspect("building instance")
  #   {:ok, instance} = Wasmex.Component.Instance.new(store, component)
  #   IO.inspect("executing component function")
  #   assert [first, second] = Wasmex.Native.exec_func(store.resource, instance.resource, "init")
  #   assert second =~ "Codebeam"
  # end

  # test "bindgen component test", %{store: store, component: component} do
  #   assert todo = Wasmex.Native.todo_instantiate(store.resource, component.resource)
  #   assert [first, second] = Wasmex.Native.todo_init(store.resource, todo)
  #   assert first =~ "Hello"
  # end

  test "with a different component impl" do
    component_bytes = File.read!("test/support/todo_list/other_todo_list.wasm")
    {:ok, store} = Wasmex.ComponentStore.new(%Wasmex.Wasi.WasiOptions{})
    {:ok, component} = Wasmex.Component.new(store, component_bytes)
    assert todo = Wasmex.Native.todo_instantiate(store.resource, component.resource)
    assert list = Wasmex.Native.todo_init(store.resource, todo)
    assert "other" in list
  end
end
