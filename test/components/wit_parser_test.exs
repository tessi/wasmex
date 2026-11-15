defmodule Components.WitParserTest do
  use ExUnit.Case

  describe "exports" do
    test "component server metadata includes record and flag names as strings" do
      wit = """
      package local:metadata;
      world metadata {
        record child { child-name: string }
        type children = list<child>;
        flags state { is-ready }
        export echo: func(items: children, states: state) -> children;
      }
      """

      assert {%{"echo" => 2}, fields} =
               Wasmex.Native.wit_component_server_metadata("metadata.wit", wit)

      assert Enum.sort(fields) == ["child-name", "is-ready"]
    end

    test "exported_functions" do
      wit = File.read!("test/component_fixtures/hello_world/hello-world.wit")

      assert %{"greet" => 1, "greet-many" => 1, "multi-greet" => 2} =
               Wasmex.Native.wit_exported_functions("hello-world.wit", wit)
    end

    test "wit parse errors" do
      wit = "goo goo"
      assert {:error, error} = Wasmex.Native.wit_exported_functions("hello-world.wit", wit)
      assert error =~ "Failed to parse WIT"

      assert {:error, metadata_error} =
               Wasmex.Native.wit_component_server_metadata("hello-world.wit", wit)

      assert metadata_error =~ "Failed to parse WIT"
    end
  end
end
