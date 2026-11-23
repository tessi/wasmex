defmodule Wasmex.Components.TypedByteListsTest do
  use ExUnit.Case, async: true

  alias Wasmex.Components

  test "passes binary arguments and accepts byte lists for the same signature" do
    pid = start_component()

    assert {:ok, {:ok, 258}} = Components.call_function(pid, "count-bytes", [<<0, 128, 255>>])
    assert {:ok, {:ok, 258}} = Components.call_function(pid, "count-bytes", [[0, 128, 255]])
    assert {:ok, {:ok, 0}} = Components.call_function(pid, "count-bytes", [<<>>])
    assert {:error, _} = Components.call_function(pid, "count-bytes", [<<1::1>>])
  end

  test "passes bytes beside a string or integer and rejects invalid byte values" do
    pid = start_component()

    for input <- [<<0, 128, 255>>, [0, 128, 255]] do
      assert {:ok, {:ok, 258}} = Components.call_function(pid, "count-labeled", [:label, input])
      assert {:ok, 263} = Components.call_function(pid, "count-then-label", [input, :label])
      assert {:ok, 265} = Components.call_function(pid, "count-with-offset", [input, 7])
      assert {:ok, 265} = Components.call_function(pid, "offset-then-count", [7, input])
    end

    for invalid <- [<<1::1>>, [256], [-1], [0 | 1]] do
      assert {:error, _} = Components.call_function(pid, "count-labeled", ["", invalid])
    end

    assert {:error, "Could not convert Atom to U8 at \"list[1]\""} =
             Components.call_function(pid, "count-labeled", ["", [0, :bad]])

    assert {:ok, {:ok, 0}} = Components.call_function(pid, "count-labeled", ["", <<>>])
  end

  test "keeps binary results valid after guest cleanup, later calls and instance shutdown" do
    pid = start_component(binary_byte_lists: true)

    assert {:ok, {:ok, first}} = Components.call_function(pid, "read-buffer", [255, "label"])

    assert {:ok, {:ok, <<128, 0::size(1016)>>}} =
             Components.call_function(pid, "read-buffer", [128, :label])

    assert {:ok, {:ok, <<>>}} = Components.call_function(pid, "read-buffer", [0, ""])
    assert {:ok, {:error, "bad"}} = Components.call_function(pid, "read-buffer", [999, ""])

    assert {:error, "Could not convert Integer to String"} =
             Components.call_function(pid, "read-buffer", [1, 2])

    stop_supervised!(Components)
    assert first == <<255, 0::size(1016)>>
  end

  test "uses the configured default list representation for the same signature" do
    pid = start_component()

    assert {:ok, {:ok, [255 | remaining]}} =
             Components.call_function(pid, "read-buffer", [255, "label"])

    assert remaining == List.duplicate(0, 127)
    assert {:ok, {:ok, []}} = Components.call_function(pid, "read-buffer", [0, ""])
  end

  defp start_component(opts \\ []) do
    wat = File.read!("test/component_fixtures/typed_byte_lists.wat")
    assert {:ok, bytes} = Wasmex.Wat.to_wasm(wat)
    start_supervised!({Components, Keyword.put(opts, :bytes, bytes)})
  end
end
