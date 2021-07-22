defmodule WasiTest do
  use ExUnit.Case, async: true
  doctest Wasmex

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

  test "calling a normal WASM module with WASI enabled errors as no WASI version can be detected" do
    assert {:error,
            {{:bad_return_value, {:error, "Could not create import object: UnknownWasiVersion"}},
             _}} =
             start_supervised(
               {Wasmex, %{module: TestHelper.wasm_module(), imports: %{}, wasi: true}}
             )
  end

  test "running a WASM/WASI module while overriding some WASI methods" do
    imports = %{
      wasi_snapshot_preview1: %{
        clock_time_get:
          {:fn, [:i32, :i64, :i32], [:i32],
           fn %{memory: memory}, _clock_id, _precision, time_ptr ->
             # writes a time struct into memory representing 42 seconds since the epoch

             # 64-bit tv_sec
             Wasmex.Memory.set(memory, time_ptr + 0, 0)
             Wasmex.Memory.set(memory, time_ptr + 1, 0)
             Wasmex.Memory.set(memory, time_ptr + 2, 0)
             Wasmex.Memory.set(memory, time_ptr + 3, 0)
             Wasmex.Memory.set(memory, time_ptr + 4, 10)
             Wasmex.Memory.set(memory, time_ptr + 5, 0)
             Wasmex.Memory.set(memory, time_ptr + 6, 0)
             Wasmex.Memory.set(memory, time_ptr + 7, 0)

             # 64-bit n_sec
             Wasmex.Memory.set(memory, time_ptr + 8, 0)
             Wasmex.Memory.set(memory, time_ptr + 9, 0)
             Wasmex.Memory.set(memory, time_ptr + 10, 0)
             Wasmex.Memory.set(memory, time_ptr + 11, 0)
             Wasmex.Memory.set(memory, time_ptr + 12, 0)
             Wasmex.Memory.set(memory, time_ptr + 13, 0)
             Wasmex.Memory.set(memory, time_ptr + 14, 0)
             Wasmex.Memory.set(memory, time_ptr + 15, 0)

             0
           end},
        random_get:
          {:fn, [:i32, :i32], [:i32],
           fn %{memory: memory}, address, size ->
             Enum.each(0..size, fn index ->
               Wasmex.Memory.set(memory, address + index, 0)
             end)

             # randomly selected `4` with a fair dice roll
             Wasmex.Memory.set(memory, address, 4)

             0
           end}
      }
    }

    {:ok, pipe} = Wasmex.Pipe.create()

    wasi = %{
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
        {Wasmex, %{module: TestHelper.wasi_module(), imports: imports, wasi: wasi}}
      )

    {:ok, _} = Wasmex.call_function(instance, :_start, [])

    assert Wasmex.Pipe.read(pipe) ==
             """
             Hello from the WASI test program!

             Arguments:
             wasmex
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

  test "file system access without preopened dirs" do
    {:ok, stdout} = Wasmex.Pipe.create()
    wasi = %{args: ["list_files", "src"], stdout: stdout}
    instance = start_supervised!({Wasmex, %{module: TestHelper.wasi_module(), wasi: wasi}})

    {:ok, _} = Wasmex.call_function(instance, :_start, [])
    assert Wasmex.Pipe.read(stdout) == "Could not find directory src\n"
  end

  test "list files on a preopened dir" do
    {:ok, stdout} = Wasmex.Pipe.create()

    wasi = %{
      args: ["list_files", "test/wasi_test/src"],
      stdout: stdout,
      preopen: %{"test/wasi_test/src": %{flags: [:read]}}
    }

    instance = start_supervised!({Wasmex, %{module: TestHelper.wasi_module(), wasi: wasi}})

    {:ok, _} = Wasmex.call_function(instance, :_start, [])
    assert Wasmex.Pipe.read(stdout) == "\"test/wasi_test/src/main.rs\"\n"
  end

  test "list files on a preopened dir with alias" do
    {:ok, stdout} = Wasmex.Pipe.create()

    wasi = %{
      args: ["list_files", "aliased_src"],
      stdout: stdout,
      preopen: %{"test/wasi_test/src": %{flags: [:read], alias: "aliased_src"}}
    }

    instance = start_supervised!({Wasmex, %{module: TestHelper.wasi_module(), wasi: wasi}})

    {:ok, _} = Wasmex.call_function(instance, :_start, [])
    assert Wasmex.Pipe.read(stdout) == "\"aliased_src/main.rs\"\n"
  end

  test "read a file on a preopened dir" do
    {:ok, stdout} = Wasmex.Pipe.create()

    wasi = %{
      args: ["read_file", "src/main.rs"],
      stdout: stdout,
      preopen: %{"test/wasi_test/src": %{flags: [:read], alias: "src"}}
    }

    instance = start_supervised!({Wasmex, %{module: TestHelper.wasi_module(), wasi: wasi}})

    {:ok, _} = Wasmex.call_function(instance, :_start, [])
    {:ok, expected_content} = File.read("test/wasi_test/src/main.rs")
    assert Wasmex.Pipe.read(stdout) == expected_content <> "\n"
  end

  test "attempt to read a file without read permission" do
    {:ok, stdout} = Wasmex.Pipe.create()

    wasi = %{
      args: ["read_file", "src/main.rs"],
      stdout: stdout,
      preopen: %{"test/wasi_test/src": %{flags: [:create], alias: "src"}}
    }

    instance = start_supervised!({Wasmex, %{module: TestHelper.wasi_module(), wasi: wasi}})

    {:ok, _} = Wasmex.call_function(instance, :_start, [])

    assert Wasmex.Pipe.read(stdout) ==
             "error: could not read file (Os { code: 2, kind: PermissionDenied, message: \"Permission denied\" })\n"
  end

  test "write a file on a preopened dir" do
    {dir, filename, filepath} = tmp_file_path("write_file")
    File.write!(filepath, "existing content\n")

    {:ok, stdout} = Wasmex.Pipe.create()

    wasi = %{
      args: ["write_file", "src/#{filename}"],
      stdout: stdout,
      preopen: %{dir => %{flags: [:write], alias: "src"}}
    }

    instance = start_supervised!({Wasmex, %{module: TestHelper.wasi_module(), wasi: wasi}})
    {:ok, _} = Wasmex.call_function(instance, :_start, [])

    {:ok, file_contents} = File.read(filepath)
    assert "Hello, updated world!" == file_contents
    assert Wasmex.Pipe.read(stdout) == ""
    File.rm!(filepath)
  end

  test "write a file on a preopened dir without permission" do
    {dir, filename, filepath} = tmp_file_path("write_file_no_permission")
    File.write!(filepath, "existing content\n")

    {:ok, stdout} = Wasmex.Pipe.create()

    wasi = %{
      args: ["write_file", "src/#{filename}"],
      stdout: stdout,
      preopen: %{dir => %{flags: [:read], alias: "src"}}
    }

    instance = start_supervised!({Wasmex, %{module: TestHelper.wasi_module(), wasi: wasi}})
    {:ok, _} = Wasmex.call_function(instance, :_start, [])

    {:ok, file_contents} = File.read(filepath)
    assert "existing content\n" == file_contents

    assert Wasmex.Pipe.read(stdout) ==
             "error: could not write file (Os { code: 2, kind: PermissionDenied, message: \"Permission denied\" })\n"

    File.rm!(filepath)
  end

  test "create a file on a preopened dir" do
    {dir, filename, filepath} = tmp_file_path("create_file")

    {:ok, stdout} = Wasmex.Pipe.create()

    wasi = %{
      args: ["create_file", "src/#{filename}"],
      stdout: stdout,
      preopen: %{dir => %{flags: [:create], alias: "src"}}
    }

    instance = start_supervised!({Wasmex, %{module: TestHelper.wasi_module(), wasi: wasi}})
    {:ok, _} = Wasmex.call_function(instance, :_start, [])

    {:ok, file_contents} = File.read(filepath)
    assert "Hello, created world!" == file_contents
    assert Wasmex.Pipe.read(stdout) == ""
    File.rm!(filepath)
  end

  test "create a file on a preopened dir without permission" do
    {dir, filename, filepath} = tmp_file_path("create_file")

    {:ok, stdout} = Wasmex.Pipe.create()

    wasi = %{
      args: ["create_file", "src/#{filename}"],
      stdout: stdout,
      preopen: %{dir => %{flags: [:read], alias: "src"}}
    }

    instance = start_supervised!({Wasmex, %{module: TestHelper.wasi_module(), wasi: wasi}})
    {:ok, _} = Wasmex.call_function(instance, :_start, [])

    {:ok, file_contents} = File.read(filepath)
    assert "" == file_contents

    assert Wasmex.Pipe.read(stdout) ==
             "error: could not write file (Os { code: 2, kind: PermissionDenied, message: \"Permission denied\" })\n"

    File.rm!(filepath)
  end
end
