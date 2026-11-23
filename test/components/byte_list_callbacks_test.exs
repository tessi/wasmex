defmodule Wasmex.Components.ByteListCallbacksTest do
  use ExUnit.Case, async: true

  alias Wasmex.Components

  test "round-trips bare callback bytes with both output representations" do
    for binary? <- [false, true] do
      replies = [<<0, 128, 255>>, [0, 128, 255], <<>>]
      pid = start_callback("$bytes", &Enum.fetch!(replies, &1), binary?)
      expected = if binary?, do: <<0, 128, 255>>, else: [0, 128, 255]
      assert {:ok, ^expected} = Components.call_function(pid, "read", [0])
      assert {:ok, ^expected} = Components.call_function(pid, "read", [1])
      empty = if binary?, do: <<>>, else: []
      assert {:ok, ^empty} = Components.call_function(pid, "read", [2])
      stop_supervised!(Components)
    end
  end

  test "preserves option and result tags, payloads and errors" do
    for {type, replies, expected} <- [
          {"(option $bytes)", [{:some, []}, :none, {:some, <<255>>}],
           [{:some, <<>>}, :none, {:some, <<255>>}]},
          {"(result $bytes (error string))", [{:ok, [128, 255]}, {:error, :missing}],
           [{:ok, <<128, 255>>}, {:error, "missing"}]},
          {"(result $bytes (error u32))", [{:error, 42}, {:ok, <<>>}],
           [{:error, 42}, {:ok, <<>>}]},
          {"(result $bytes)", [:error, {:ok, <<255>>}], [:error, {:ok, <<255>>}]}
        ] do
      pid = start_callback(type, &Enum.fetch!(replies, &1), true)

      for {value, index} <- Enum.with_index(expected) do
        assert {:ok, ^value} = Components.call_function(pid, "read", [index])
      end

      stop_supervised!(Components)
    end
  end

  test "calls interface imports with a string key or no arguments" do
    wat = File.read!("test/component_fixtures/byte_list_interface.wat")
    assert {:ok, bytes} = Wasmex.Wat.to_wasm(wat)

    imports = %{
      "store" => %{
        "lookup" => {:fn, fn "key" -> <<255, 128, 0>> end},
        "default" => {:fn, fn -> [42] end}
      }
    }

    pid = start_supervised!({Components, bytes: bytes, imports: imports, binary_byte_lists: true})
    assert {:ok, <<255, 128, 0>>} = Components.call_function(pid, "lookup", [])
    assert {:ok, <<42>>} = Components.call_function(pid, "default", [])
  end

  test "invalid callback bytes return an error" do
    for invalid <- [[256], [1 | 2], <<1::1>>] do
      pid = start_callback("(result $bytes (error string))", fn _ -> {:ok, invalid} end, true)
      assert {:error, _reason} = Components.call_function(pid, "read", [0])
      stop_supervised!(Components)
    end
  end

  # Forward a host result through guest memory so assertions inspect the complete value.
  defp start_callback(result, callback, binary?) do
    wat = """
    (component
      (type $bytes (list u8))
      (import "fetch" (func $fetch (param "key" u32) (result #{result})))
      (core module $mem
        (memory (export "memory") 1)
        (func (export "realloc") (param i32 i32 i32 i32) (result i32) i32.const 128))
      (core instance $mem (instantiate $mem))
      (alias core export $mem "memory" (core memory $memory))
      (alias core export $mem "realloc" (core func $realloc))
      (core func $fetch (canon lower (func $fetch) (memory $memory) (realloc $realloc)))
      (core module $guest
        (import "" "fetch" (func $fetch (param i32 i32)))
        (func (export "read") (param i32) (result i32)
          local.get 0 i32.const 16 call $fetch i32.const 16))
      (core instance $guest (instantiate $guest
        (with "" (instance (export "fetch" (func $fetch))))))
      (func (export "read") (param "key" u32) (result #{result})
        (canon lift (core func $guest "read") (memory $memory))))
    """

    assert {:ok, bytes} = Wasmex.Wat.to_wasm(wat)

    start_supervised!(
      {Components,
       bytes: bytes, imports: %{"fetch" => {:fn, callback}}, binary_byte_lists: binary?}
    )
  end
end
