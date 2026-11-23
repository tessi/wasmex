defmodule Wasmex.Components.ByteListLiftingTest do
  use ExUnit.Case, async: true

  alias Wasmex.Components

  @large_size 8 * 1024 * 1024

  test "returns large byte lists before guest cleanup can change their contents" do
    pid = start_component(true)
    assert {:ok, bytes} = Components.call_function(pid, "read", [@large_size])
    assert byte_size(bytes) == @large_size
    assert {:ok, <<171>>} = Components.call_function(pid, "read", [1])
    assert {:ok, <<>>} = Components.call_function(pid, "read-empty", [])
    assert {:ok, <<171, 171, 171>>} = Components.call_function(pid, "read-string", [:abc])
    assert {:ok, {:ok, <<171>>}} = Components.call_function(pid, "read-result", [1, "x"])
    stop_supervised!(Components)
    assert bytes == :binary.copy(<<171>>, @large_size)
  end

  test "sends a binary callback argument that survives guest memory reuse" do
    pid = start_component(true)
    assert {:ok, @large_size} = Components.call_function(pid, "call-consume", [@large_size])
    assert_receive {:consume, bytes}
    assert {:ok, []} = Components.call_function(pid, "call-notify", [0])
    assert_receive {:notify, <<>>}
    stop_supervised!(Components)
    assert bytes == :binary.copy(<<171>>, @large_size)
  end

  test "uses lists for export results and callback arguments by default" do
    pid = start_component(false)
    assert {:ok, [171, 171]} = Components.call_function(pid, "read", [2])
    assert {:ok, []} = Components.call_function(pid, "read-empty", [])
    assert {:ok, {:ok, [171]}} = Components.call_function(pid, "read-result", [1, "x"])
    assert {:ok, 2} = Components.call_function(pid, "call-consume", [2])
    assert_receive {:consume, [171, 171]}
  end

  test "rejects an out-of-bounds byte list before invoking the callback" do
    pid = start_component(true)
    assert {:error, _reason} = Components.call_function(pid, "call-invalid-pointer", [])
    refute_received {:consume, _}
  end

  defp start_component(binary_byte_lists) do
    test_pid = self()
    wat = File.read!("test/component_fixtures/component_byte_list_lifting.wat")
    assert {:ok, bytes} = Wasmex.Wat.to_wasm(wat)

    consume = fn bytes ->
      send(test_pid, {:consume, bytes})
      if is_binary(bytes), do: byte_size(bytes), else: length(bytes)
    end

    notify = fn bytes -> send(test_pid, {:notify, bytes}) end

    start_supervised!(
      {Components,
       bytes: bytes,
       binary_byte_lists: binary_byte_lists,
       imports: %{"consume" => {:fn, consume}, "notify" => {:fn, notify}}}
    )
  end
end
