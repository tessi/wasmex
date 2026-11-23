defmodule Wasmex.PipeTest do
  use ExUnit.Case, async: true
  import TestHelper, only: [t: 1]

  alias Wasmex.Pipe
  doctest Pipe

  defp build_pipe(_) do
    {:ok, pipe} = Pipe.new()
    %{pipe: pipe}
  end

  describe "buffer limits" do
    test "rejects oversized writes atomically while allowing overwrites" do
      {:ok, pipe} = Pipe.new(max_size: 5)
      assert Pipe.write(pipe, "hello") == {:ok, 5}
      assert Pipe.seek(pipe, 4) == :ok
      assert Pipe.write(pipe, "xy") == :error
      assert Pipe.read(pipe) == "o"
      assert Pipe.size(pipe) == 5
      assert Pipe.write(pipe, "!") == :error
      assert Pipe.seek(pipe, 1) == :ok
      assert Pipe.write(pipe, "a") == {:ok, 1}
      assert Pipe.seek(pipe, 0) == :ok
      assert Pipe.read(pipe) == "hallo"
    end

    test "sparse writes and huge positions cannot bypass the limit" do
      {:ok, pipe} = Pipe.new(max_size: 4)
      assert Pipe.seek(pipe, 3) == :ok
      assert Pipe.write(pipe, "x") == {:ok, 1}
      assert Pipe.seek(pipe, 0) == :ok
      assert Pipe.read(pipe) == <<0, 0, 0, ?x>>
      assert Pipe.seek(pipe, 18_446_744_073_709_551_615) == :ok
      assert Pipe.write(pipe, "x") == :error
      assert Pipe.write(pipe, "") == :error
      assert Pipe.size(pipe) == 4
    end

    test "default limit rejects large sparse extensions without allocating them" do
      {:ok, pipe} = Pipe.new()
      assert Pipe.seek(pipe, 256 * 1024 * 1024) == :ok
      assert Pipe.write(pipe, "x") == :error
      assert Pipe.size(pipe) == 0
    end

    test "custom limits can exceed the default without allocating up front" do
      {:ok, pipe} = Pipe.new(max_size: 512 * 1024 * 1024)
      assert Pipe.size(pipe) == 0
      assert Pipe.write(pipe, "hello") == {:ok, 5}
    end

    test "zero limit accepts only empty writes at the start" do
      {:ok, pipe} = Pipe.new(max_size: 0)
      assert Pipe.write(pipe, "") == {:ok, 0}
      assert Pipe.write(pipe, "x") == :error
      assert Pipe.size(pipe) == 0
    end

    test "rejects invalid limit options" do
      for max_size <- [-1, nil, :infinity, 1.5] do
        assert_raise ArgumentError, fn -> Pipe.new(max_size: max_size) end
        assert_raise ArgumentError, fn -> Wasmex.Native.pipe_new_with_limit(max_size) end
      end

      assert_raise ArgumentError, fn -> Pipe.new(unknown: 1) end

      assert_raise ArgumentError, fn ->
        Wasmex.Native.pipe_new_with_limit(Integer.pow(2, 128))
      end
    end

    test "WASI stdout and stderr share the retained buffer limit" do
      bytes = ~S"""
      (module
        (import "wasi_snapshot_preview1" "fd_write"
          (func $fd_write (param i32 i32 i32 i32) (result i32)))
        (memory (export "memory") 1)
        (data (i32.const 0) "\10\00\00\00\04\00\00\00")
        (data (i32.const 16) "abcd")
        (func (export "write") (param $fd i32) (result i32)
          local.get $fd
          i32.const 0
          i32.const 1
          i32.const 8
          call $fd_write))
      """

      {:ok, pipe} = Pipe.new(max_size: 8)

      {:ok, store} =
        Wasmex.Store.new_wasi(
          %Wasmex.Wasi.WasiOptions{stdout: pipe, stderr: pipe},
          %Wasmex.StoreLimits{memory_size: 65_536}
        )

      instance =
        start_supervised!({Wasmex, %{bytes: bytes, store: store}})

      assert Wasmex.call_function(instance, :write, [1]) == {:ok, [0]}
      assert Wasmex.call_function(instance, :write, [2]) == {:ok, [0]}

      case Wasmex.call_function(instance, :write, [1]) do
        {:ok, [errno]} -> assert errno != 0
        {:error, _reason} -> :ok
      end

      assert Pipe.size(pipe) == 8
      assert Pipe.seek(pipe, 0) == :ok
      assert Pipe.read(pipe) == "abcdabcd"
    end
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

    test "reads past the end without moving the cursor", %{pipe: pipe} do
      assert {:ok, 1} = Pipe.write(pipe, "a")
      assert :ok = Pipe.seek(pipe, 3)
      assert <<>> = Pipe.read(pipe)
      assert {:ok, 1} = Pipe.write(pipe, "b")
      assert :ok = Pipe.seek(pipe, 0)
      assert <<"a", 0, 0, "b">> = Pipe.read(pipe)
      assert :ok = Pipe.seek(pipe, 18_446_744_073_709_551_615)
      assert <<>> = Pipe.read(pipe)
      assert :error = Pipe.write(pipe, "c")
    end

    test "returns a snapshot that survives an overwrite", %{pipe: pipe} do
      bytes = :binary.copy(<<255, 0, 195, 40>>, 16_384)
      assert {:ok, 65_536} = Pipe.write(pipe, bytes)
      assert :ok = Pipe.seek(pipe, 0)
      snapshot = Pipe.read(pipe)
      assert :ok = Pipe.seek(pipe, 1)
      assert {:ok, 1} = Pipe.write(pipe, "x")
      assert snapshot == bytes
      assert :ok = Pipe.seek(pipe, 0)
      assert <<255, ?x, 195, 40, _::binary>> = Pipe.read(pipe)
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
