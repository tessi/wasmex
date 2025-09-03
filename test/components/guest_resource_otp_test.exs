defmodule Wasmex.Components.GuestResourceOTPTest do
  @moduledoc """
  Tests that generated guest resources work correctly with standard OTP supervisors.

  This demonstrates that users don't need any special supervisor - just use
  standard Supervisor and DynamicSupervisor from OTP.
  """
  use ExUnit.Case, async: false

  alias Wasmex.Components.{Store, Component, Instance}

  # Define a test counter module using code generation
  defmodule TestCounter do
    use Wasmex.Components.GuestResource,
      wit: "test/component_fixtures/counter-component/wit/world.wit",
      resource: "counter"
  end

  @counter_wasm_path "test/component_fixtures/counter-component/target/wasm32-wasip1/release/counter_component.wasm"

  setup do
    # Ensure component exists
    unless File.exists?(@counter_wasm_path) do
      raise "Counter component not found. Build with: cd test/component_fixtures/counter-component && cargo component build --release"
    end

    :ok
  end

  test "guest resources work with standard OTP supervisors" do
    children = [
      {DynamicSupervisor, strategy: :one_for_one, name: TestDynamicSup}
    ]

    {:ok, _sup} = Supervisor.start_link(children, strategy: :one_for_one)

    # Create store and instance
    {:ok, store} = Store.new()
    component_bytes = File.read!(@counter_wasm_path)
    {:ok, component} = Component.new(store, component_bytes)
    {:ok, instance} = Instance.new(store, component, %{})

    # Start multiple resources under supervision
    {:ok, counter1} =
      DynamicSupervisor.start_child(
        TestDynamicSup,
        {TestCounter, [instance, [0]]}
      )

    {:ok, counter2} =
      DynamicSupervisor.start_child(
        TestDynamicSup,
        {TestCounter, [instance, [100]]}
      )

    # Verify both are alive and independent
    assert Process.alive?(counter1)
    assert Process.alive?(counter2)
    assert {:ok, 0} = TestCounter.get_value(counter1)
    assert {:ok, 100} = TestCounter.get_value(counter2)

    # Clean up
    DynamicSupervisor.stop(TestDynamicSup)
  end

  test "supervised resources restart on crash and maintain fault isolation" do
    # Start a supervisor with restart strategy
    children = [
      {DynamicSupervisor, strategy: :one_for_one, name: TestRestartSup, max_restarts: 10}
    ]

    {:ok, _sup} = Supervisor.start_link(children, strategy: :one_for_one)

    # Create instance
    {:ok, store} = Store.new()
    component_bytes = File.read!(@counter_wasm_path)
    {:ok, component} = Component.new(store, component_bytes)
    {:ok, instance} = Instance.new(store, component, %{})

    # Start resources with permanent restart
    child_spec1 = %{
      id: :counter1,
      start: {TestCounter, :start_link, [instance, [42], [name: :test_counter1]]},
      restart: :permanent
    }

    child_spec2 = %{
      id: :counter2,
      start: {TestCounter, :start_link, [instance, [100], [name: :test_counter2]]},
      restart: :permanent
    }

    {:ok, pid1} = DynamicSupervisor.start_child(TestRestartSup, child_spec1)
    {:ok, _pid2} = DynamicSupervisor.start_child(TestRestartSup, child_spec2)

    # Verify both work
    assert {:ok, 42} = TestCounter.get_value(:test_counter1)
    assert {:ok, 100} = TestCounter.get_value(:test_counter2)

    # Kill one process
    Process.exit(pid1, :kill)

    # Wait for restart
    Process.sleep(100)

    # Check it restarted with a new PID
    new_pid = Process.whereis(:test_counter1)
    assert new_pid != nil
    assert new_pid != pid1

    # Both should still work (fault isolation)
    assert {:ok, 42} = TestCounter.get_value(:test_counter1)
    assert {:ok, 100} = TestCounter.get_value(:test_counter2)

    # Clean up
    DynamicSupervisor.stop(TestRestartSup)
  end

  test "resources are properly cleaned up when supervisor stops" do
    {:ok, sup} = Supervisor.start_link([], strategy: :one_for_one)

    # Start resources
    {:ok, store} = Store.new()
    component_bytes = File.read!(@counter_wasm_path)
    {:ok, component} = Component.new(store, component_bytes)
    {:ok, instance} = Instance.new(store, component, %{})

    pids =
      for i <- 1..3 do
        child_spec = %{
          id: :"counter_#{i}",
          start: {TestCounter, :start_link, [instance, [i * 10]]},
          restart: :permanent
        }

        {:ok, pid} = Supervisor.start_child(sup, child_spec)
        pid
      end

    # Verify all are alive
    assert Enum.all?(pids, &Process.alive?/1)

    # Stop supervisor
    Supervisor.stop(sup)

    # Wait a bit
    Process.sleep(50)

    # Verify all processes are dead
    refute Enum.any?(pids, &Process.alive?/1)
  end
end
