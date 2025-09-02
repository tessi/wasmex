defmodule Wasmex.Components.ResourceServerTest do
  use ExUnit.Case, async: true

  alias Wasmex.Components.ResourceServer
  alias Wasmex.Components.ResourceManager
  alias Wasmex.Test.Support.Examples.CounterResource

  describe "ResourceServer with CounterResource" do
    test "starts resource process successfully" do
      {:ok, pid} =
        ResourceServer.start_link(
          CounterResource,
          %{initial_value: 10, name: "test-counter"}
        )

      assert Process.alive?(pid)

      # Cleanup
      ResourceServer.stop(pid)
    end

    test "initializes with correct state" do
      {:ok, pid} = ResourceServer.start_link(CounterResource, 42)

      assert {:ok, {:ok, 42}} = ResourceServer.call_method(pid, "get-value", [])

      ResourceServer.stop(pid)
    end

    test "increment and decrement methods work" do
      {:ok, pid} = ResourceServer.start_link(CounterResource, 10)

      # Increment without parameter
      assert {:ok, {:ok, 11}} = ResourceServer.call_method(pid, "increment", [])
      assert {:ok, {:ok, 11}} = ResourceServer.call_method(pid, "get-value", [])

      # Increment with parameter
      assert {:ok, {:ok, 21}} = ResourceServer.call_method(pid, "increment", [10])
      assert {:ok, {:ok, 21}} = ResourceServer.call_method(pid, "get-value", [])

      # Decrement
      assert {:ok, {:ok, 20}} = ResourceServer.call_method(pid, "decrement", [])
      assert {:ok, {:ok, 15}} = ResourceServer.call_method(pid, "decrement", [5])
      assert {:ok, {:ok, 15}} = ResourceServer.call_method(pid, "get-value", [])

      ResourceServer.stop(pid)
    end

    test "reset method works" do
      {:ok, pid} = ResourceServer.start_link(CounterResource, 100)

      assert {:ok, {:ok, 100}} = ResourceServer.call_method(pid, "get-value", [])
      assert {:ok, {:ok, 0}} = ResourceServer.call_method(pid, "reset", [])
      assert {:ok, {:ok, 0}} = ResourceServer.call_method(pid, "get-value", [])

      ResourceServer.stop(pid)
    end

    test "name methods work" do
      {:ok, pid} =
        ResourceServer.start_link(
          CounterResource,
          %{initial_value: 0, name: "my-counter"}
        )

      assert {:ok, {:ok, "my-counter"}} = ResourceServer.call_method(pid, "get-name", [])
      assert {:ok, :ok} = ResourceServer.call_method(pid, "set-name", ["new-name"])
      assert {:ok, {:ok, "new-name"}} = ResourceServer.call_method(pid, "get-name", [])

      ResourceServer.stop(pid)
    end

    test "get-stats returns comprehensive information" do
      {:ok, pid} =
        ResourceServer.start_link(
          CounterResource,
          %{initial_value: 5, name: "stats-counter"}
        )

      # Perform some operations
      ResourceServer.call_method(pid, "increment", [])
      ResourceServer.call_method(pid, "decrement", [])
      ResourceServer.call_method(pid, "set-name", ["renamed"])

      assert {:ok, {:ok, stats}} = ResourceServer.call_method(pid, "get-stats", [])
      assert stats.value == 5
      assert stats.name == "renamed"
      assert stats.operation_count == 3
      assert stats.process == pid

      ResourceServer.stop(pid)
    end

    @tag :capture_log
    test "unknown method returns error" do
      {:ok, pid} = ResourceServer.start_link(CounterResource, 0)

      assert {:error, "Unknown method: unknown"} =
               ResourceServer.call_method(pid, "unknown", [])

      ResourceServer.stop(pid)
    end

    test "get_type_name returns correct type" do
      {:ok, pid} = ResourceServer.start_link(CounterResource, 0)

      assert {:ok, "counter"} = ResourceServer.get_type_name(pid)

      ResourceServer.stop(pid)
    end

    test "process automatically cleans up on termination" do
      {:ok, pid} =
        ResourceServer.start_link(
          CounterResource,
          %{initial_value: 999, name: "cleanup-test"}
        )

      # Verify it's alive
      assert Process.alive?(pid)

      # Stop the process
      ResourceServer.stop(pid)

      # Verify it's no longer alive
      refute Process.alive?(pid)

      # Trying to call methods should fail gracefully
      assert {:error, "Resource process no longer exists"} =
               ResourceServer.call_method(pid, "get-value", [])
    end

    @tag :capture_log
    test "process isolation - crash in one resource doesn't affect others" do
      # Start two resources
      {:ok, pid1} = ResourceServer.start_link(CounterResource, 10)
      {:ok, pid2} = ResourceServer.start_link(CounterResource, 20)

      # Verify both are working
      assert {:ok, {:ok, 10}} = ResourceServer.call_method(pid1, "get-value", [])
      assert {:ok, {:ok, 20}} = ResourceServer.call_method(pid2, "get-value", [])

      # Trap exits so we don't crash the test process
      Process.flag(:trap_exit, true)

      # Crash the first resource (this will raise an exception in the resource process)
      assert {:error, {:process_exit, _}} = ResourceServer.call_method(pid1, "crash", [])

      # Wait a moment for the crash to propagate
      :timer.sleep(10)

      # First resource should be dead
      refute Process.alive?(pid1)
      assert {:error, _} = ResourceServer.call_method(pid1, "get-value", [])

      # Second resource should still work fine
      assert Process.alive?(pid2)
      assert {:ok, {:ok, 20}} = ResourceServer.call_method(pid2, "get-value", [])
      assert {:ok, {:ok, 21}} = ResourceServer.call_method(pid2, "increment", [])

      ResourceServer.stop(pid2)
    end

    test "handles timeout gracefully" do
      {:ok, pid} = ResourceServer.start_link(CounterResource, 0)

      # This should work with a short timeout
      assert {:ok, {:ok, 0}} = ResourceServer.call_method(pid, "get-value", [], 100)

      ResourceServer.stop(pid)
    end
  end

  describe "ResourceManager" do
    setup do
      # Ensure the manager is started
      case ResourceManager.start_link() do
        {:ok, pid} ->
          on_exit(fn -> Process.exit(pid, :normal) end)
          {:ok, manager: pid}

        {:error, {:already_started, pid}} ->
          {:ok, manager: pid}
      end
    end

    test "get_resource_info provides debugging information", %{manager: _manager} do
      info = ResourceManager.get_resource_info()

      assert is_map(info)
      assert Map.has_key?(info, :active_resources)
      assert Map.has_key?(info, :next_id)
      assert Map.has_key?(info, :stores_with_resources)
      assert Map.has_key?(info, :resources_by_store)
      assert Map.has_key?(info, :resource_details)
    end
  end

  describe "Process resource lifecycle" do
    test "resource process terminates cleanly" do
      # Temporarily enable debug logging for this test
      original_level = Logger.level()
      Logger.configure(level: :debug)

      # Capture log messages
      log_capture =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, pid} =
            ResourceServer.start_link(
              CounterResource,
              %{initial_value: 42, name: "lifecycle-test"}
            )

          # Perform some operations
          ResourceServer.call_method(pid, "increment", [])
          ResourceServer.call_method(pid, "increment", [])

          # Stop the process
          ResourceServer.stop(pid)

          # Give it time to log
          :timer.sleep(10)
        end)

      # Restore original log level
      Logger.configure(level: original_level)

      # Verify termination was logged
      assert log_capture =~ "CounterResource terminating"
      assert log_capture =~ "lifecycle-test"
      assert log_capture =~ "final value: 44"
      assert log_capture =~ "operations performed: 2"
    end

    test "multiple resources can run concurrently" do
      # Start multiple resources
      pids =
        for i <- 1..10 do
          {:ok, pid} =
            ResourceServer.start_link(
              CounterResource,
              %{initial_value: i, name: "counter-#{i}"}
            )

          pid
        end

      # Verify all are alive
      assert Enum.all?(pids, &Process.alive?/1)

      # Call methods on all of them
      results =
        for {pid, i} <- Enum.with_index(pids, 1) do
          {:ok, {:ok, value}} = ResourceServer.call_method(pid, "get-value", [])
          assert value == i

          {:ok, {:ok, new_value}} = ResourceServer.call_method(pid, "increment", [10])
          assert new_value == i + 10

          new_value
        end

      assert results == Enum.to_list(11..20)

      # Clean up
      Enum.each(pids, &ResourceServer.stop/1)
    end
  end

  describe "Error handling" do
    test "invalid module fails to start" do
      defmodule InvalidResource do
        # Does not implement the behaviour
      end

      # The GenServer will exit during init, which is expected
      Process.flag(:trap_exit, true)
      result = ResourceServer.start_link(InvalidResource, %{})

      # Should receive an exit signal
      assert match?({:error, {:error, _}}, result) or
               (receive do
                  {:EXIT, _, {:error, _}} -> true
                after
                  100 -> false
                end)
    end

    test "init failure is handled gracefully" do
      defmodule FailingResource do
        @behaviour Wasmex.Components.ResourceBehaviour

        def type_name, do: "failing-resource"

        def init(_args) do
          {:error, "Initialization failed"}
        end

        def handle_method(_, _, state), do: {:reply, nil, state}
      end

      # The GenServer will exit during init with the error reason
      Process.flag(:trap_exit, true)
      result = ResourceServer.start_link(FailingResource, %{})

      assert match?({:error, {:error, "Initialization failed"}}, result) or
               (receive do
                  {:EXIT, _, {:error, "Initialization failed"}} -> true
                after
                  100 -> false
                end)
    end
  end
end
