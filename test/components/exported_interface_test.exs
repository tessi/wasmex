defmodule Wasmex.Components.ExportedInterfaceTest do
  use ExUnit.Case, async: true

  describe "component type conversions" do
    defmodule Point, do: defstruct([:x, :y])
    defmodule Tag, do: defstruct([:id])

    def start_component() do
      component_bytes = File.read!(TestHelper.component_exported_interface_file_path())

      start_supervised!(
        {Wasmex.Components,
         bytes: component_bytes,
         imports: %{
           "wasmex:simple/get@0.1.0" => %{"get" => {:fn, fn -> %Tag{id: "hello!"} end}}
         }}
      )
    end

    test "call function by path using a string tuple" do
      component_pid = start_component()

      assert {:ok, 165} =
               Wasmex.Components.call_function(
                 component_pid,
                 {"wasmex:simple/add@0.1.0", "add"},
                 [123, 42]
               )
    end

    test "call function by path using an atom tuple" do
      component_pid = start_component()

      assert {:ok, 165} =
               Wasmex.Components.call_function(
                 component_pid,
                 {:"wasmex:simple/add@0.1.0", :add},
                 [123, 42]
               )
    end

    test "call function by path using a string list" do
      component_pid = start_component()

      assert {:ok, 165} =
               Wasmex.Components.call_function(
                 component_pid,
                 ["wasmex:simple/add@0.1.0", "add"],
                 [123, 42]
               )
    end

    test "call function by path using an atom list" do
      component_pid = start_component()

      assert {:ok, 165} =
               Wasmex.Components.call_function(
                 component_pid,
                 [:"wasmex:simple/add@0.1.0", :add],
                 [123, 42]
               )
    end

    test "call non-existent function on existing component" do
      component_pid = start_component()

      assert {:error, message} =
               Wasmex.Components.call_function(
                 component_pid,
                 [:"wasmex:simple/add@0.1.0", :non_existent_function],
                 [123, 42]
               )

      assert "exported function `[wasmex:simple/add@0.1.0, non_existent_function]` not found. Could not find `non_existent_function` at position 1" ==
               message
    end

    test "call non-existent components function" do
      component_pid = start_component()

      assert {:error, message} =
               Wasmex.Components.call_function(
                 component_pid,
                 ["non-existent", :add],
                 [123, 42]
               )

      assert "exported function `[non-existent, add]` not found. Could not find `non-existent` at position 0" ==
               message
    end

    test "call empty list" do
      component_pid = start_component()

      assert {:error, message} =
               Wasmex.Components.call_function(
                 component_pid,
                 [],
                 [123, 42]
               )

      assert "exported function `` not found." == message
    end

    test "call root non-existent function" do
      component_pid = start_component()

      assert {:error, message} =
               Wasmex.Components.call_function(
                 component_pid,
                 :non_existent_function,
                 [123, 42]
               )

      assert "exported function `non_existent_function` not found." == message
    end

    test "call function which in turn calls into an imported module" do
      component_pid = start_component()

      assert {:ok, 6} =
               Wasmex.Components.call_function(
                 component_pid,
                 {"wasmex:simple/add@0.1.0", "call-into-imported-module-func"},
                 []
               )
    end
  end
end
