defmodule Wasmex.Components.ImportTest do
  use ExUnit.Case
  alias Wasmex.Wasi.WasiP2Options

  test "import functions" do
    component_bytes = File.read!("test/component_fixtures/importer/importer.wasm")

    # Use Agent to capture printed values
    {:ok, print_agent} = Agent.start_link(fn -> [] end)

    print_message = fn msg ->
      Agent.update(print_agent, &[msg | &1])
      nil
    end

    read_messages = fn -> Agent.get(print_agent, & &1) end
    clear_messages = fn -> Agent.update(print_agent, fn _ -> [] end) end

    imports = %{
      "get-secret-word" => {:fn, fn param1, param2 -> "#{param1} #{param2}" end},
      "get-number" => {:fn, fn -> 42 end},
      "get-list" => {:fn, fn -> ["hi", "there"] end},
      "get-point" => {:fn, fn -> %{x: 1, y: 2} end},
      "get-tuple" => {:fn, fn -> {1, "foo"} end},
      "print" => {:fn, print_message},
      "maybe-get-number" => {:fn, fn -> {:ok, 42} end}
    }

    component_pid =
      start_supervised!(
        {Wasmex.Components,
         bytes: component_bytes,
         wasi: %WasiP2Options{inherit_stdout: true, allow_http: true},
         imports: imports}
      )

    assert {:ok, "7 foo 42 hi,there x: 1 y: 2"} =
             Wasmex.Components.call_function(component_pid, "reveal-secret-word", [7])

    assert read_messages.() == []

    assert {:ok, "1 foo"} =
             Wasmex.Components.call_function(component_pid, "show-tuple", [])

    assert read_messages.() == []

    assert {:ok, []} = Wasmex.Components.call_function(component_pid, "print-secret-word", [])
    assert read_messages.() == ["7 foo"]
    clear_messages.()

    assert {:ok, {:ok, "bananas"}} =
             Wasmex.Components.call_function(component_pid, "print-or-error", ["bananas"])

    assert read_messages.() == ["bananas"]
    clear_messages.()

    assert {:ok, {:error, "error"}} =
             Wasmex.Components.call_function(component_pid, "print-or-error", ["error"])

    assert read_messages.() == ["error"]

    assert {:ok, {:ok, 42}} =
             Wasmex.Components.call_function(component_pid, "maybe-return-number", [])

    assert read_messages.() == ["error"]
  end
end
