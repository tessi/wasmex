defmodule Wasmex.Components.ImportTest do
  use ExUnit.Case
  alias Wasmex.Wasi.WasiP2Options

  test "import functions" do
    component_bytes = File.read!("test/component_fixtures/importer/importer.wasm")

    # Use Agent to capture printed values for verification
    {:ok, print_agent} = Agent.start_link(fn -> [] end)

    imports = %{
      "get-secret-word" => {:fn, fn param1, param2 -> "#{param1} #{param2}" end},
      "get-number" => {:fn, fn -> 42 end},
      "get-list" => {:fn, fn -> ["hi", "there"] end},
      "get-point" => {:fn, fn -> %{x: 1, y: 2} end},
      "get-tuple" => {:fn, fn -> {1, "foo"} end},
      # Capture printed values for verification instead of suppressing
      "print" =>
        {:fn,
         fn x ->
           Agent.update(print_agent, fn values -> [x | values] end)
           :ok
         end},
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

    assert {:ok, "1 foo"} =
             Wasmex.Components.call_function(component_pid, "show-tuple", [])

    # Verify the print function is called with the correct value
    assert {:ok, _} = Wasmex.Components.call_function(component_pid, "print-secret-word", [])
    assert Agent.get(print_agent, & &1) == ["7 foo"]

    # Clear the agent for next test
    Agent.update(print_agent, fn _ -> [] end)

    # Verify print function is called with "bananas"
    assert {:ok, {:ok, "bananas"}} =
             Wasmex.Components.call_function(component_pid, "print-or-error", ["bananas"])

    assert Agent.get(print_agent, & &1) == ["bananas"]

    # Clear the agent for next test
    Agent.update(print_agent, fn _ -> [] end)

    # Verify print function is called with "error"
    assert {:ok, {:error, "error"}} =
             Wasmex.Components.call_function(component_pid, "print-or-error", ["error"])

    assert Agent.get(print_agent, & &1) == ["error"]

    assert {:ok, {:ok, 42}} =
             Wasmex.Components.call_function(component_pid, "maybe-return-number", [])
  end
end
