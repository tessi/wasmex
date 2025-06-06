defmodule WasiTest do
  use ExUnit.Case, async: true

  alias Wasmex.Wasi.PreopenOptions
  alias Wasmex.Wasi.WasiOptions

  def tmp_file_path(suffix) do
    dir = System.tmp_dir!()

    now =
      DateTime.utc_now()
      |> DateTime.to_iso8601()
      |> String.replace(~r{[:.]}, "_")

    rand = to_string(:rand.uniform(1000))
    filename = "wasi_test_#{now}_#{rand}_#{suffix}.tmp"
    {dir, filename, Path.join(dir, filename)}
  end

  test "running a Wasm/WASI module while overriding some WASI methods" do
    imports = %{
      wasi_snapshot_preview1: %{
        clock_time_get:
          {:fn, [:i32, :i64, :i32], [:i32],
           fn %{memory: memory, caller: caller}, _clock_id, _precision, time_ptr ->
             # writes a time struct into memory representing 42 seconds since the epoch

             # 64-bit tv_sec
             Wasmex.Memory.set_byte(caller, memory, time_ptr + 0, 0)
             Wasmex.Memory.set_byte(caller, memory, time_ptr + 1, 0)
             Wasmex.Memory.set_byte(caller, memory, time_ptr + 2, 0)
             Wasmex.Memory.set_byte(caller, memory, time_ptr + 3, 0)
             Wasmex.Memory.set_byte(caller, memory, time_ptr + 4, 10)
             Wasmex.Memory.set_byte(caller, memory, time_ptr + 5, 0)
             Wasmex.Memory.set_byte(caller, memory, time_ptr + 6, 0)
             Wasmex.Memory.set_byte(caller, memory, time_ptr + 7, 0)

             # 64-bit n_sec
             Wasmex.Memory.set_byte(caller, memory, time_ptr + 8, 0)
             Wasmex.Memory.set_byte(caller, memory, time_ptr + 9, 0)
             Wasmex.Memory.set_byte(caller, memory, time_ptr + 10, 0)
             Wasmex.Memory.set_byte(caller, memory, time_ptr + 11, 0)
             Wasmex.Memory.set_byte(caller, memory, time_ptr + 12, 0)
             Wasmex.Memory.set_byte(caller, memory, time_ptr + 13, 0)
             Wasmex.Memory.set_byte(caller, memory, time_ptr + 14, 0)
             Wasmex.Memory.set_byte(caller, memory, time_ptr + 15, 0)

             0
           end},
        random_get:
          {:fn, [:i32, :i32], [:i32],
           fn %{memory: memory, caller: caller}, address, size ->
             Enum.each(0..size, fn index ->
               Wasmex.Memory.set_byte(caller, memory, address + index, 0)
             end)

             # randomly selected `4` with a fair dice roll
             Wasmex.Memory.set_byte(caller, memory, address, 4)

             0
           end}
      }
    }

    {:ok, pipe} = Wasmex.Pipe.new()

    wasi = %WasiOptions{
      args: ["hello", "from elixir"],
      env: %{
        "A_NAME_MAPS" => "to a value",
        "THE_TEST_WASI_FILE" => "prints all environment variables"
      },
      stdin: pipe,
      stdout: pipe,
      stderr: pipe
    }

    instance =
      start_supervised!(
        {Wasmex,
         %{bytes: File.read!(TestHelper.wasi_test_file_path()), imports: imports, wasi: wasi}}
      )

    {:ok, _} = Wasmex.call_function(instance, :_start, [])

    Wasmex.Pipe.seek(pipe, 0)

    assert Wasmex.Pipe.read(pipe) ==
             """
             Hello from the WASI test program!

             Arguments:
             hello
             from elixir

             Environment:
             A_NAME_MAPS=to a value
             THE_TEST_WASI_FILE=prints all environment variables

             Current Time (Since Unix Epoch):
             42

             Random Number: 4

             """
  end

  test "echo stdin" do
    {:ok, stdin} = Wasmex.Pipe.new()
    {:ok, stdout} = Wasmex.Pipe.new()

    wasi_options = %Wasmex.Wasi.WasiOptions{
      args: ["wasmex", "echo"],
      stdin: stdin,
      stdout: stdout
    }

    {:ok, pid} =
      Wasmex.start_link(%{
        bytes: File.read!(TestHelper.wasi_test_file_path()),
        wasi: wasi_options
      })

    Wasmex.Pipe.write(stdin, "Hey! It compiles! Ship it!")
    Wasmex.Pipe.seek(stdin, 0)
    {:ok, _} = Wasmex.call_function(pid, :_start, [])
    Wasmex.Pipe.seek(stdout, 0)
    assert Wasmex.Pipe.read(stdout) == "Hey! It compiles! Ship it!\n"
  end

  test "file system access without preopened dirs" do
    {:ok, stdout} = Wasmex.Pipe.new()
    wasi = %WasiOptions{args: ["wasmex", "list_files", "src"], stdout: stdout}

    instance =
      start_supervised!(
        {Wasmex, %{bytes: File.read!(TestHelper.wasi_test_file_path()), wasi: wasi}}
      )

    {:ok, _} = Wasmex.call_function(instance, :_start, [])
    Wasmex.Pipe.seek(stdout, 0)
    assert Wasmex.Pipe.read(stdout) == "Could not find directory src\n"
  end

  test "list files on a preopened dir with all permissions" do
    {:ok, stdout} = Wasmex.Pipe.new()

    wasi = %WasiOptions{
      args: ["wasmex", "list_files", "test/fixture_projects/wasi_test/src"],
      stdout: stdout,
      preopen: [%PreopenOptions{path: "test/fixture_projects/wasi_test/src"}]
    }

    instance =
      start_supervised!(
        {Wasmex, %{bytes: File.read!(TestHelper.wasi_test_file_path()), wasi: wasi}}
      )

    {:ok, _} = Wasmex.call_function(instance, :_start, [])
    Wasmex.Pipe.seek(stdout, 0)
    assert Wasmex.Pipe.read(stdout) == "\"test/fixture_projects/wasi_test/src/main.rs\"\n"
  end

  test "list files on a preopened dir with alias" do
    {:ok, stdout} = Wasmex.Pipe.new()

    wasi = %WasiOptions{
      args: ["wasmex", "list_files", "aliased_src"],
      stdout: stdout,
      preopen: [
        %PreopenOptions{path: "test/fixture_projects/wasi_test/src", alias: "aliased_src"}
      ]
    }

    instance =
      start_supervised!(
        {Wasmex, %{bytes: File.read!(TestHelper.wasi_test_file_path()), wasi: wasi}}
      )

    {:ok, _} = Wasmex.call_function(instance, :_start, [])
    Wasmex.Pipe.seek(stdout, 0)
    assert Wasmex.Pipe.read(stdout) == "\"aliased_src/main.rs\"\n"
  end

  test "read a file on a preopened dir" do
    {:ok, stdout} = Wasmex.Pipe.new()

    wasi = %WasiOptions{
      args: ["wasmex", "read_file", "src/main.rs"],
      stdout: stdout,
      preopen: [%PreopenOptions{path: "test/fixture_projects/wasi_test/src", alias: "src"}]
    }

    instance =
      start_supervised!(
        {Wasmex, %{bytes: File.read!(TestHelper.wasi_test_file_path()), wasi: wasi}}
      )

    {:ok, _} = Wasmex.call_function(instance, :_start, [])
    {:ok, expected_content} = File.read("test/fixture_projects/wasi_test/src/main.rs")
    Wasmex.Pipe.seek(stdout, 0)
    assert Wasmex.Pipe.read(stdout) == expected_content <> "\n"
  end

  test "write a file on a preopened dir" do
    {dir, filename, filepath} = tmp_file_path("write_file")
    File.write!(filepath, "existing content\n")

    {:ok, stdout} = Wasmex.Pipe.new()

    wasi = %WasiOptions{
      args: ["wasmex", "write_file", "src/#{filename}"],
      stdout: stdout,
      preopen: [%PreopenOptions{path: dir, alias: "src"}]
    }

    instance =
      start_supervised!(
        {Wasmex, %{bytes: File.read!(TestHelper.wasi_test_file_path()), wasi: wasi}}
      )

    {:ok, _} = Wasmex.call_function(instance, :_start, [])

    Wasmex.Pipe.seek(stdout, 0)
    assert Wasmex.Pipe.read(stdout) == ""

    {:ok, file_contents} = File.read(filepath)
    assert "Hello, updated world!" == file_contents

    File.rm!(filepath)
  end

  test "create a file on a preopened dir" do
    {dir, filename, filepath} = tmp_file_path("create_file")

    {:ok, stdout} = Wasmex.Pipe.new()

    wasi = %WasiOptions{
      args: ["wasmex", "create_file", "src/#{filename}"],
      stdout: stdout,
      preopen: [%PreopenOptions{path: dir, alias: "src"}]
    }

    instance =
      start_supervised!(
        {Wasmex, %{bytes: File.read!(TestHelper.wasi_test_file_path()), wasi: wasi}}
      )

    {:ok, _} = Wasmex.call_function(instance, :_start, [])

    {:ok, file_contents} = File.read(filepath)
    assert "Hello, created world!" == file_contents

    Wasmex.Pipe.seek(stdout, 0)
    assert Wasmex.Pipe.read(stdout) == ""
    File.rm!(filepath)
  end
end
