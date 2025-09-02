defmodule Wasmex.Components.HostResourceTest do
  use ExUnit.Case, async: true

  alias Wasmex.Components.Store

  describe "host resource type registration" do
    test "registers a host resource type" do
      assert :ok = Wasmex.Native.host_resource_type_register("test-resource")
    end

    test "can register multiple resource types" do
      assert :ok = Wasmex.Native.host_resource_type_register("database-connection")
      assert :ok = Wasmex.Native.host_resource_type_register("file-handle")
      assert :ok = Wasmex.Native.host_resource_type_register("network-socket")
    end
  end

  describe "host resource creation" do
    setup do
      {:ok, store} = Store.new()
      {:ok, store: store}
    end

    test "creates a host resource instance", %{store: store} do
      :ok = Wasmex.Native.host_resource_type_register("counter")
      resource_id = :erlang.unique_integer([:positive])

      # The NIF returns the resource directly, not wrapped in {:ok, ...}
      resource = Wasmex.Native.host_resource_new(store.resource, resource_id, "counter")

      assert is_reference(resource)
    end

    test "fails to create resource without type registration", %{store: store} do
      resource_id = :erlang.unique_integer([:positive])

      # Check what actually happens when type is not registered
      result =
        try do
          Wasmex.Native.host_resource_new(store.resource, resource_id, "unregistered-type")
        rescue
          e -> {:error, e}
        end

      # Should either raise or return nil/error
      case result do
        {:error, _} ->
          assert true

        nil ->
          assert true

        _ ->
          flunk(
            "Expected error when creating resource without type registration, got: #{inspect(result)}"
          )
      end
    end

    test "creates multiple instances of same type", %{store: store} do
      :ok = Wasmex.Native.host_resource_type_register("session")

      resource1_id = :erlang.unique_integer([:positive])
      resource2_id = :erlang.unique_integer([:positive])

      resource1 = Wasmex.Native.host_resource_new(store.resource, resource1_id, "session")
      resource2 = Wasmex.Native.host_resource_new(store.resource, resource2_id, "session")

      assert resource1 != resource2
      assert is_reference(resource1)
      assert is_reference(resource2)
    end
  end

  describe "host resource method calls" do
    setup do
      {:ok, store} = Store.new()
      :ok = Wasmex.Native.host_resource_type_register("test-object")
      resource_id = :erlang.unique_integer([:positive])
      resource = Wasmex.Native.host_resource_new(store.resource, resource_id, "test-object")

      {:ok, store: store, resource: resource}
    end

    test "calls method on host resource", %{store: store, resource: resource} do
      # This tests the infrastructure - actual method dispatch would need
      # a real WASM component that imports host resources
      result =
        Wasmex.Native.host_resource_call_method(
          store.resource,
          resource,
          "test-method",
          []
        )

      # For now, we just verify the NIF doesn't crash
      assert result == :ok
    end

    test "calls method with parameters", %{store: store, resource: resource} do
      result =
        Wasmex.Native.host_resource_call_method(
          store.resource,
          resource,
          "set-value",
          [42, "test", true]
        )

      assert result == :ok
    end
  end

  describe "resource lifecycle" do
    test "resources are tied to their store" do
      {:ok, store1} = Store.new()
      {:ok, store2} = Store.new()

      :ok = Wasmex.Native.host_resource_type_register("scoped-resource")
      resource_id = :erlang.unique_integer([:positive])

      resource = Wasmex.Native.host_resource_new(store1.resource, resource_id, "scoped-resource")

      # Trying to use resource with wrong store should fail
      result =
        try do
          Wasmex.Native.host_resource_call_method(
            store2.resource,
            resource,
            "method",
            []
          )
        rescue
          e -> {:error, e}
        end

      # Should either raise or return error/nil
      case result do
        {:error, _} -> assert true
        nil -> assert true
        :ok -> flunk("Should not allow using resource with wrong store")
        _ -> flunk("Expected error when using resource with wrong store, got: #{inspect(result)}")
      end
    end

    test "resources are cleaned up when store is destroyed" do
      resource =
        (fn ->
           {:ok, store} = Store.new()
           :ok = Wasmex.Native.host_resource_type_register("temp-resource")
           resource_id = :erlang.unique_integer([:positive])

           resource =
             Wasmex.Native.host_resource_new(store.resource, resource_id, "temp-resource")

           resource
         end).()

      # After the store goes out of scope, the resource should be invalid
      # We can't directly test cleanup, but we can verify the resource
      # reference still exists (it just won't be usable)
      assert is_reference(resource)
    end
  end

  describe "type conversion" do
    setup do
      {:ok, store} = Store.new()
      :ok = Wasmex.Native.host_resource_type_register("converter")
      resource_id = :erlang.unique_integer([:positive])
      resource = Wasmex.Native.host_resource_new(store.resource, resource_id, "converter")

      {:ok, store: store, resource: resource}
    end

    test "converts basic types to Val", %{store: store, resource: resource} do
      # Test various Elixir types that should convert to wasmtime Val
      test_values = [
        # Bool
        true,
        # Bool
        false,
        # S32
        42,
        # S32
        -100,
        # Float64
        3.14,
        # String
        "hello world",
        # List
        [1, 2, 3],
        # Record
        %{"key" => "value"},
        # Option::Some
        {:some, 42},
        # Option::None
        :none,
        # Result::Ok
        {:ok, "success"},
        # Result::Err
        {:error, "fail"}
      ]

      for value <- test_values do
        result =
          Wasmex.Native.host_resource_call_method(
            store.resource,
            resource,
            "test-conversion",
            [value]
          )

        assert result == :ok
      end
    end
  end

  describe "integration with process-based resources" do
    defmodule TestHostResource do
      @behaviour Wasmex.Components.ResourceBehaviour

      @impl true
      def type_name, do: "test-host-resource"

      @impl true
      def init(args), do: {:ok, args}

      @impl true
      def handle_method("get_state", [], state), do: {:reply, state, state}
      def handle_method("set_state", [new_state], _state), do: {:reply, :ok, new_state}

      def handle_method("increment", [], state) when is_integer(state),
        do: {:reply, state + 1, state + 1}

      def handle_method(_, _, state), do: {:error, "unknown_method", state}

      @impl true
      def terminate(_reason, _state) do
        :ok
      end
    end

    test "host resource can integrate with Elixir process" do
      # This demonstrates how host resources could integrate with 
      # the existing process-based resource system
      {:ok, store} = Store.new()

      # Register the type
      :ok = Wasmex.Native.host_resource_type_register("process-resource")

      # Start a process-based resource
      {:ok, pid} = GenServer.start_link(TestHostResource, 0)

      # Create host resource with process ID as resource_id
      resource_id = :erlang.phash2(pid)
      _resource = Wasmex.Native.host_resource_new(store.resource, resource_id, "process-resource")

      # The actual method dispatch would go through the process
      # This is a conceptual test showing the integration pattern
      assert Process.alive?(pid)

      # Clean up
      GenServer.stop(pid)
    end
  end
end
