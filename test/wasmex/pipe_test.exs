defmodule Wasmex.PipeTest do
  use ExUnit.Case, async: true
  doctest Wasmex.Pipe

  defp build_pipe(_) do
    {:ok, pipe} = Wasmex.Pipe.create()
    %{pipe: pipe}
  end

  describe "size/1 && set_len/2" do
    setup :build_pipe

    test "returns the pipes size and allowes resizing", %{pipe: pipe} do
      assert Wasmex.Pipe.size(pipe) == 0
      Wasmex.Pipe.set_len(pipe, 42)
      assert Wasmex.Pipe.size(pipe) == 42
    end
  end

  describe "read/1 && write/2" do
    setup :build_pipe

    test "allows reads and writes", %{pipe: pipe} do
      assert Wasmex.Pipe.read(pipe) == ""
      assert {:ok, 13} == Wasmex.Pipe.write(pipe, "Hello, World!")
      assert Wasmex.Pipe.read(pipe) == "Hello, World!"
    end
  end
end
