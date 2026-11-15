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

    test "preserves arbitrary binary bytes and byte positions", %{pipe: pipe} do
      bytes = <<0, 255, 195, 40, 226, 130>>
      assert Pipe.write(pipe, bytes) == {:ok, byte_size(bytes)}
      assert Pipe.read(pipe) == ""
      assert Pipe.size(pipe) == byte_size(bytes)
      assert Pipe.seek(pipe, 0) == :ok
      assert Pipe.read(pipe) == bytes
      assert Pipe.seek(pipe, 2) == :ok
      assert Pipe.read(pipe) == <<195, 40, 226, 130>>
      assert Pipe.seek(pipe, 1) == :ok
      assert Pipe.write(pipe, <<128>>) == {:ok, 1}
      assert Pipe.seek(pipe, 0) == :ok
      assert Pipe.read(pipe) == <<0, 128, 195, 40, 226, 130>>
    end

    test "#{t(&Pipe.seek/2)} sets pipe position", %{pipe: pipe} do
      Pipe.write(pipe, "Hello, World!")
      Pipe.seek(pipe, 7)
      Pipe.write(pipe, "Wasmex")
      Pipe.seek(pipe, 0)
      assert Pipe.read(pipe) == "Hello, Wasmex"
    end
  end

  test "reads arbitrary WASI stdout and stderr bytes without poisoning the pipe" do
    wat = ~S"""
    (module
      (import "wasi_snapshot_preview1" "fd_write"
        (func $fd_write (param i32 i32 i32 i32) (result i32)))
      (memory (export "memory") 1)
      (data (i32.const 16) "\ff\00\c3\28\e2\82hello")
      (func (export "write") (param $fd i32) (param $offset i32) (param $len i32) (result i32)
        (i32.store (i32.const 0) (local.get $offset))
        (i32.store (i32.const 4) (local.get $len))
        (call $fd_write (local.get $fd) (i32.const 0) (i32.const 1) (i32.const 8))))
    """

    for {fd, stream} <- [{1, :stdout}, {2, :stderr}],
        {offset, bytes} <- [{16, <<255, 0, 195, 40>>}, {20, <<226, 130>>}, {22, "hello"}] do
      {:ok, pipe} = Pipe.new()
      wasi = Map.put(%Wasmex.Wasi.WasiOptions{}, stream, pipe)

      instance = start_supervised!({Wasmex, %{bytes: wat, wasi: wasi}}, id: {stream, offset})

      assert Wasmex.call_function(instance, "write", [fd, offset, byte_size(bytes)]) == {:ok, [0]}
      assert Pipe.read(pipe) == ""
      assert Pipe.seek(pipe, 0) == :ok
      assert Pipe.read(pipe) == bytes
      assert Pipe.size(pipe) == byte_size(bytes)
      assert Pipe.read(pipe) == ""
      assert Pipe.seek(pipe, 0) == :ok
      assert Pipe.read(pipe) == bytes
      assert Pipe.write(pipe, "!") == {:ok, 1}
      assert Pipe.seek(pipe, byte_size(bytes)) == :ok
      assert Pipe.read(pipe) == "!"
    end
  end
end
