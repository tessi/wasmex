defmodule Wasmex.StoreTest do
  use ExUnit.Case, async: true
  import TestHelper, only: [t: 1]

  doctest Wasmex.Store

  describe t(&Store.new/0) do
    test "creates a new Store" do
      assert {:ok, %Wasmex.StoreOrCaller{}} = Wasmex.Store.new()
    end
  end

  describe t(&Store.new_wasi/1) do
    test "creates a new Store with Wasi Options" do
      assert {:ok, %Wasmex.StoreOrCaller{}} =
               Wasmex.Store.new_wasi(%Wasmex.Wasi.WasiOptions{
                 args: ["arg1", "arg2"],
                 env: %{"key1" => "value1", "key2" => "value2"}
               })
    end
  end
end
