defmodule Wasmex.PipeTest do
  use ExUnit.Case, async: true
  import TestHelper, only: [t: 1]

  alias Wasmex.Pipe
  doctest Pipe

  defp build_pipe(_) do
    {:ok, pipe} = Pipe.new()
    %{pipe: pipe}
  end

  describe t(&Pipe.size/1) do
    setup :build_pipe

    test "new pipes have a size of 0", %{pipe: pipe} do
      assert Pipe.size(pipe) == 0
    end

    test "pipes with content, report a positive size", %{pipe: pipe} do
      Pipe.write(pipe, "123")
      assert Pipe.size(pipe) == 3
    end

    test "seek position doesn't change the pipes size", %{pipe: pipe} do
      Pipe.write(pipe, "ninechars")
      assert Pipe.size(pipe) == 9
      assert Pipe.seek(pipe, 2)
      assert Pipe.size(pipe) == 9
    end
  end

  describe t(&Pipe.read/1) <> t(&Pipe.write/2) <> t(&Pipe.seek/2) do
    setup :build_pipe

    test "allows reads and writes", %{pipe: pipe} do
      assert Pipe.read(pipe) == ""

      assert {:ok, 13} == Pipe.write(pipe, "Hello, World!")
      # current read position of that pipe is at EOL
      assert Pipe.read(pipe) == ""
      assert Pipe.seek(pipe, 0) == :ok
      assert Pipe.read(pipe) == "Hello, World!"
    end

    test "#{t(&Pipe.seek/2)} sets pipe position", %{pipe: pipe} do
      Pipe.write(pipe, "Hello, World!")
      Pipe.seek(pipe, 7)
      Pipe.write(pipe, "Wasmex")
      Pipe.seek(pipe, 0)
      assert Pipe.read(pipe) == "Hello, Wasmex"
    end
  end
end
