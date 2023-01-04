defmodule Wasmex.StoreTest do
  use ExUnit.Case, async: true
  import TestHelper, only: [t: 1]

  doctest Wasmex.Store

  describe t(&Store.new/0) do
    test "creates a new Store" do
      assert {:ok, %Wasmex.StoreOrCaller{}} = Wasmex.Store.new()
    end
  end

  describe t(&Store.new/1) do
    test "creates a new Store with limits lower than the default 17 pages" do
      limits = %Wasmex.StoreLimits{memory_size: 1_000}
      assert {:ok, store} = Wasmex.Store.new(limits)
      {:ok, module} = Wasmex.Module.compile(store, File.read!(TestHelper.wasm_test_file_path()))

      {:error, "memory minimum size of 17 pages exceeds memory limits"} =
        Wasmex.Instance.new(store, module, %{})
    end

    test "creates a new Store with limits at exactly the default 17 pages" do
      page_size = 64 * 1024
      limits = %Wasmex.StoreLimits{memory_size: page_size * 17}
      assert {:ok, store} = Wasmex.Store.new(limits)
      {:ok, module} = Wasmex.Module.compile(store, File.read!(TestHelper.wasm_test_file_path()))
      {:ok, instance} = Wasmex.Instance.new(store, module, %{})

      # The memory is 17 pages by default, so we can't grow it by 1 page
      {:ok, memory} = Wasmex.Instance.memory(store, instance)

      assert {:error, "Failed to grow the memory: failed to grow memory by `1`."} =
               Wasmex.Memory.grow(store, memory, 1)
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
