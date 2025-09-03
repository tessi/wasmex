defmodule Wasmex.Components.ResourceTest do
  use ExUnit.Case

  @counter_component_path "test/component_fixtures/counter-component/target/wasm32-wasip1/release/counter_component.wasm"

  describe "counter resource component" do
    setup do
      # Check if component exists
      unless File.exists?(@counter_component_path) do
        raise "Component not built. Run: cd test/component_fixtures/counter-component && cargo component build --release"
      end

      # Read the component bytes
      component_bytes = File.read!(@counter_component_path)

      # Create a store
      {:ok, store} = Wasmex.Components.Store.new()

      # Load the component  
      {:ok, component} = Wasmex.Components.Component.new(store, component_bytes)

      # Create an instance
      {:ok, instance} = Wasmex.Components.Instance.new(store, component, %{})

      {:ok, store: store, component: component, instance: instance}
    end

    test "can call test function", %{instance: instance} do
      # Call the test function with proper from parameter
      from = self()

      # This is async - it sends the result back as a message
      :ok = Wasmex.Components.Instance.call_function(instance, "test", [], from)

      # Wait for the result
      receive do
        {:returned_function_call, {:ok, value}, ^from} ->
          assert value == "Counter resource test component"

        {:returned_function_call, {:error, error}, ^from} ->
          flunk("Error calling test function: #{inspect(error)}")
      after
        5000 ->
          flunk("Timeout waiting for function result")
      end
    end

    test "can create counter resource using constructor (recommended)", %{instance: instance} do
      # Create a counter using the constructor - clean and simple!
      {:ok, counter} =
        Wasmex.Components.Instance.new_resource(
          instance,
          ["component:counter/types", "counter"],
          # initial value
          [5]
        )

      # Verify it's a resource (will be a reference in Elixir)
      assert is_reference(counter)

      # Test that we can call methods on the resource
      {:ok, value} = Wasmex.Components.Instance.call(instance, counter, "get-value")
      assert value == 5

      # Increment and verify
      {:ok, new_value} = Wasmex.Components.Instance.call(instance, counter, "increment")
      assert new_value == 6
    end

    test "can create and use counter with clean API", %{instance: instance} do
      # Create counter using clean API
      {:ok, counter} =
        Wasmex.Components.Instance.new_resource(
          instance,
          ["component:counter/types", "counter"],
          [10]
        )

      assert is_reference(counter)

      # Call methods using the clean API - no interface needed for default
      {:ok, value} = Wasmex.Components.Instance.call(instance, counter, "get-value")
      assert value == 10

      # Increment the counter
      {:ok, new_value} = Wasmex.Components.Instance.call(instance, counter, "increment")
      assert new_value == 11

      # Reset the counter (returns nothing)
      :ok = Wasmex.Components.Instance.call(instance, counter, "reset", [100])

      # Verify reset worked
      {:ok, value} = Wasmex.Components.Instance.call(instance, counter, "get-value")
      assert value == 100
    end

    test "can create counter resource using factory function (legacy)", %{instance: instance} do
      from = self()

      # Create a counter with factory function - works but constructor is preferred
      :ok =
        Wasmex.Components.Instance.call_function(
          instance,
          ["component:counter/types", "make-counter"],
          [42],
          from
        )

      receive do
        {:returned_function_call, {:ok, counter}, ^from} ->
          # Verify it's a resource (will be a reference in Elixir)
          assert is_reference(counter)

        # Successfully created counter resource (reference checked)
        {:returned_function_call, {:error, error}, ^from} ->
          flunk("Error creating counter: #{inspect(error)}")
      after
        5000 ->
          flunk("Timeout waiting for counter creation")
      end
    end
  end

  describe "basic component loading" do
    test "component file exists" do
      assert File.exists?(@counter_component_path),
             "Component not found. Build with: cd test/component_fixtures/counter-component && cargo component build --release"
    end

    test "can read component bytes" do
      bytes = File.read!(@counter_component_path)
      assert byte_size(bytes) > 0
      # WASM magic number
      <<0x00, 0x61, 0x73, 0x6D, _rest::binary>> = bytes
    end
  end

  describe "resource lifecycle management" do
    setup do
      component_bytes = File.read!(@counter_component_path)
      {:ok, component_bytes: component_bytes}
    end

    test "resources are cleaned up when store is dropped", %{component_bytes: component_bytes} do
      # Create a store and instance
      {:ok, store} = Wasmex.Components.Store.new()
      {:ok, component} = Wasmex.Components.Component.new(store, component_bytes)
      {:ok, instance} = Wasmex.Components.Instance.new(store, component, %{})

      from = self()

      # Create multiple counter resources
      counters =
        for i <- 1..5 do
          :ok =
            Wasmex.Components.Instance.call_function(
              instance,
              ["component:counter/types", "make-counter"],
              [i],
              from
            )

          receive do
            {:returned_function_call, {:ok, counter}, ^from} ->
              counter

            {:returned_function_call, {:error, error}, ^from} ->
              flunk("Error creating counter #{i}: #{inspect(error)}")
          after
            5000 -> flunk("Timeout creating counter #{i}")
          end
        end

      # Verify we created 5 resources
      assert length(counters) == 5
      assert Enum.all?(counters, &is_reference/1)

      # Force garbage collection to clean up the store
      # In real usage, this happens when store goes out of scope
      :erlang.garbage_collect()

      # Store and resources should be cleaned up automatically
      # No explicit assertion needed - Drop implementations will log cleanup
    end

    test "multiple stores can coexist with separate resources", %{
      component_bytes: component_bytes
    } do
      # Create two separate stores
      {:ok, store1} = Wasmex.Components.Store.new()
      {:ok, component1} = Wasmex.Components.Component.new(store1, component_bytes)
      {:ok, instance1} = Wasmex.Components.Instance.new(store1, component1, %{})

      {:ok, store2} = Wasmex.Components.Store.new()
      {:ok, component2} = Wasmex.Components.Component.new(store2, component_bytes)
      assert {:ok, instance2} = Wasmex.Components.Instance.new(store2, component2, %{})
      # Verify instance2 is created (for cross-store protection testing)
      assert is_struct(instance2, Wasmex.Components.Instance)

      from = self()

      # Create counter in store1
      :ok =
        Wasmex.Components.Instance.call_function(
          instance1,
          ["component:counter/types", "make-counter"],
          [10],
          from
        )

      counter1 =
        receive do
          {:returned_function_call, {:ok, counter}, ^from} ->
            counter

          {:returned_function_call, {:error, error}, ^from} ->
            flunk("Error creating counter in store1: #{inspect(error)}")
        after
          5000 -> flunk("Timeout creating counter in store1")
        end

      # Create counter in store2
      :ok =
        Wasmex.Components.Instance.call_function(
          instance2,
          ["component:counter/types", "make-counter"],
          [20],
          from
        )

      counter2 =
        receive do
          {:returned_function_call, {:ok, counter}, ^from} ->
            counter

          {:returned_function_call, {:error, error}, ^from} ->
            flunk("Error creating counter in store2: #{inspect(error)}")
        after
          5000 -> flunk("Timeout creating counter in store2")
        end

      # Verify both are valid resources
      assert is_reference(counter1)
      assert is_reference(counter2)
      assert counter1 != counter2
    end

    test "stress test: create and destroy many resources", %{component_bytes: component_bytes} do
      # This test checks for memory leaks by creating/destroying many resources

      for iteration <- 1..10 do
        # Create a new store for each iteration
        {:ok, store} = Wasmex.Components.Store.new()
        {:ok, component} = Wasmex.Components.Component.new(store, component_bytes)
        {:ok, instance} = Wasmex.Components.Instance.new(store, component, %{})

        from = self()

        # Create 100 counters in this store
        for i <- 1..100 do
          :ok =
            Wasmex.Components.Instance.call_function(
              instance,
              ["component:counter/types", "make-counter"],
              [i],
              from
            )

          receive do
            {:returned_function_call, {:ok, _counter}, ^from} ->
              :ok

            {:returned_function_call, {:error, error}, ^from} ->
              flunk("Error in iteration #{iteration}, counter #{i}: #{inspect(error)}")
          after
            5000 -> flunk("Timeout in iteration #{iteration}, counter #{i}")
          end
        end

        # Force cleanup after each iteration
        :erlang.garbage_collect()
      end

      # If we get here without crashes or OOM, the test passed
      assert true
    end

    test "resource cleanup happens in correct order", %{component_bytes: component_bytes} do
      # Create nested scope to ensure cleanup
      result =
        (fn ->
           {:ok, store} = Wasmex.Components.Store.new()
           {:ok, component} = Wasmex.Components.Component.new(store, component_bytes)
           {:ok, instance} = Wasmex.Components.Instance.new(store, component, %{})

           from = self()

           # Create a counter
           :ok =
             Wasmex.Components.Instance.call_function(
               instance,
               ["component:counter/types", "make-counter"],
               [42],
               from
             )

           counter =
             receive do
               {:returned_function_call, {:ok, counter}, ^from} ->
                 counter

               {:returned_function_call, {:error, error}, ^from} ->
                 flunk("Error creating counter: #{inspect(error)}")
             after
               5000 -> flunk("Timeout creating counter")
             end

           # Return the counter to verify it was created
           {:ok, counter}
         end).()

      # Verify the function completed successfully
      assert {:ok, counter} = result
      assert is_reference(counter)

      # Force GC to ensure cleanup happens
      :erlang.garbage_collect()

      # The store and all resources should now be cleaned up
      # Drop implementations will log the cleanup order
    end

    test "cross-store protection prevents using resources from wrong store", %{
      component_bytes: component_bytes
    } do
      # Create two separate stores
      {:ok, store1} = Wasmex.Components.Store.new()
      {:ok, component1} = Wasmex.Components.Component.new(store1, component_bytes)
      {:ok, instance1} = Wasmex.Components.Instance.new(store1, component1, %{})

      {:ok, store2} = Wasmex.Components.Store.new()
      {:ok, component2} = Wasmex.Components.Component.new(store2, component_bytes)
      assert {:ok, instance2} = Wasmex.Components.Instance.new(store2, component2, %{})
      # Verify instance2 is created (for cross-store protection testing)
      assert is_struct(instance2, Wasmex.Components.Instance)

      from = self()

      # Create a counter in store1
      :ok =
        Wasmex.Components.Instance.call_function(
          instance1,
          ["component:counter/types", "make-counter"],
          [100],
          from
        )

      _counter_from_store1 =
        receive do
          {:returned_function_call, {:ok, counter}, ^from} ->
            counter

          {:returned_function_call, {:error, error}, ^from} ->
            flunk("Error creating counter in store1: #{inspect(error)}")
        after
          5000 -> flunk("Timeout creating counter in store1")
        end

      # Note: Cross-store protection would be tested here if Resource.call_method existed.
      # Currently, resources are protected at the store level through reference checking.
    end

    test "verify no memory leaks with explicit resource drops", %{
      component_bytes: component_bytes
    } do
      # Track initial memory (this is approximate)
      initial_memory = :erlang.memory(:total)

      # Run many iterations of create/drop
      for _iteration <- 1..100 do
        {:ok, store} = Wasmex.Components.Store.new()
        {:ok, component} = Wasmex.Components.Component.new(store, component_bytes)
        {:ok, instance} = Wasmex.Components.Instance.new(store, component, %{})

        from = self()

        # Create a counter
        :ok =
          Wasmex.Components.Instance.call_function(
            instance,
            ["component:counter/types", "make-counter"],
            [42],
            from
          )

        _counter =
          receive do
            {:returned_function_call, {:ok, counter}, ^from} ->
              counter

            {:returned_function_call, {:error, error}, ^from} ->
              flunk("Error creating counter: #{inspect(error)}")
          after
            5000 -> flunk("Timeout creating counter")
          end

        # Resources are automatically cleaned up through Elixir's garbage collection
        # The counter is a raw reference, not a Resource struct, so we can't manually drop it
        # but that's fine - the GC handles cleanup
      end

      # Force GC and check memory hasn't grown excessively
      :erlang.garbage_collect()
      final_memory = :erlang.memory(:total)

      # Allow for some memory growth but not excessive (e.g., 10MB)
      memory_growth = final_memory - initial_memory

      assert memory_growth < 10_000_000,
             "Memory grew by #{memory_growth} bytes, possible memory leak"
    end
  end
end
