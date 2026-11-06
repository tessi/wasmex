defmodule Wasmex.StoreTest do
  use ExUnit.Case, async: true
  import TestHelper, only: [t: 1]

  doctest Wasmex.Store
  doctest Wasmex.StoreLimits

  @page_size 64 * 1024
  @memory_limit_pages div(256 * 1024 * 1024, @page_size)
  @table_limit 100_000

  @growth_exports """
    (memory 1)
    (table 1 funcref)
    (func (export "grow-memory") (param i32) (result i32)
      local.get 0
      memory.grow)
    (func (export "grow-table") (param i32) (result i32)
      ref.null func
      local.get 0
      table.grow 0)
  """

  @growth_module "(module #{@growth_exports})"

  @growth_component """
  (component
    (core module $guest #{@growth_exports})
    (core instance $instance (instantiate $guest))
    (func (export "grow-memory") (param "delta" u32) (result s32)
      (canon lift (core func $instance "grow-memory")))
    (func (export "grow-table") (param "delta" u32) (result s32)
      (canon lift (core func $instance "grow-table"))))
  """

  describe "default resource limits" do
    for {name, options} <- [core: %{}, wasi: %{wasi: %Wasmex.Wasi.WasiOptions{}}] do
      test "bounds guest growth in a #{name} store" do
        options = Map.put(unquote(Macro.escape(options)), :bytes, @growth_module)
        pid = start_supervised!({Wasmex, options})

        assert {:ok, [-1]} = Wasmex.call_function(pid, "grow-memory", [@memory_limit_pages])
        assert {:ok, [-1]} = Wasmex.call_function(pid, "grow-table", [@table_limit])
        assert {:ok, [1]} = Wasmex.call_function(pid, "grow-memory", [1])
        assert {:ok, [1]} = Wasmex.call_function(pid, "grow-table", [1])
      end
    end

    for {name, options} <- [
          component: [],
          component_wasi: [wasi: %Wasmex.Wasi.WasiP2Options{}],
          partial_limits: [store_limits: %Wasmex.StoreLimits{instances: 2}]
        ] do
      test "bounds guest growth in a #{name} store" do
        assert {:ok, bytes} = Wasmex.Wat.to_wasm(@growth_component)

        pid =
          start_supervised!({Wasmex.Components, [bytes: bytes] ++ unquote(Macro.escape(options))})

        assert {:ok, -1} =
                 Wasmex.Components.call_function(pid, "grow-memory", [@memory_limit_pages])

        assert {:ok, -1} = Wasmex.Components.call_function(pid, "grow-table", [@table_limit])
        assert {:ok, 1} = Wasmex.Components.call_function(pid, "grow-memory", [1])
        assert {:ok, 1} = Wasmex.Components.call_function(pid, "grow-table", [1])
      end
    end

    test "rejects oversized initial memories and tables" do
      assert {:ok, store} = Wasmex.Store.new(%Wasmex.StoreLimits{})

      assert {:ok, module} =
               Wasmex.Module.compile(store, "(module (memory #{@memory_limit_pages + 1}))")

      assert {:error, reason} = Wasmex.Instance.new(store, module, %{})
      assert reason =~ "exceeds memory limits"

      assert {:ok, module} =
               Wasmex.Module.compile(store, "(module (table #{@table_limit + 1} funcref))")

      assert {:error, reason} = Wasmex.Instance.new(store, module, %{})
      assert reason =~ "exceeds table limits"
    end

    test "honors explicit limits below and above the defaults" do
      limits = %Wasmex.StoreLimits{memory_size: @page_size, table_elements: @table_limit + 1}
      assert {:ok, store} = Wasmex.Store.new(limits)
      pid = start_supervised!({Wasmex, %{bytes: @growth_module, store: store}})

      assert {:ok, [-1]} = Wasmex.call_function(pid, "grow-memory", [1])
      assert {:ok, [1]} = Wasmex.call_function(pid, "grow-table", [@table_limit])
      assert {:ok, [-1]} = Wasmex.call_function(pid, "grow-table", [1])
    end
  end

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
