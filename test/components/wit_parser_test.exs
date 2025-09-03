defmodule Wasmex.Components.WitParserTest do
  use ExUnit.Case

  describe "exports" do
    test "exported_functions" do
      wit = File.read!("test/component_fixtures/hello_world/hello-world.wit")

      assert %{"greet" => 1, "greet-many" => 1, "multi-greet" => 2} =
               Wasmex.Native.wit_exported_functions("hello-world.wit", wit)
    end

    test "wit parse errors" do
      wit = "goo goo"
      assert {:error, error} = Wasmex.Native.wit_exported_functions("hello-world.wit", wit)
      assert error =~ "Failed to parse WIT"
    end
  end
end
