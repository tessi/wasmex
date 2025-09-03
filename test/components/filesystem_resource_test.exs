defmodule Wasmex.Components.FilesystemResourceTest do
  # Can't be async - filesystem conflicts
  use ExUnit.Case, async: false

  alias Wasmex.Test.FilesystemSandbox
  alias Wasmex.Wasi.WasiP2Options
  alias Wasmex.Components.{Store, Component, Instance}

  setup do
    # Create isolated sandbox for this test
    sandbox_dir = FilesystemSandbox.setup()

    # Create store with real filesystem access
    {:ok, store} =
      Store.new_wasi(%WasiP2Options{
        preopen_dirs: [
          Path.join(sandbox_dir, "input"),
          Path.join(sandbox_dir, "output"),
          Path.join(sandbox_dir, "work")
        ],
        # See WASI errors
        inherit_stdout: true,
        inherit_stderr: true
      })

    # Load component
    component_path =
      "test/component_fixtures/filesystem-component/target/wasm32-wasip2/wasi-release/filesystem_component_final.wasm"

    component_bytes = File.read!(component_path)
    {:ok, component} = Component.new(store, component_bytes)
    {:ok, instance} = Instance.new(store, component, %{})

    on_exit(fn -> FilesystemSandbox.cleanup(sandbox_dir) end)

    %{
      instance: instance,
      sandbox_dir: sandbox_dir,
      store: store
    }
  end

  # Helper function to call WASM functions synchronously
  defp call_sync(instance, path, args, timeout \\ 5000) do
    from = self()
    :ok = Instance.call_function(instance, path, args, from)

    receive do
      {:returned_function_call, result, ^from} -> result
    after
      timeout -> {:error, :timeout}
    end
  end

  # Helper to unwrap Result types from WIT
  defp unwrap_result(result, error_msg) do
    case result do
      # Result<T, String> returns nested ok
      {:ok, {:ok, value}} -> value
      {:ok, value} when not is_tuple(value) or elem(value, 0) != :error -> value
      {:error, _} = error -> flunk("#{error_msg}: #{inspect(error)}")
      {:ok, {:error, msg}} -> flunk("#{error_msg}: #{msg}")
      other -> flunk("#{error_msg}: unexpected result #{inspect(other)}")
    end
  end

  describe "filesystem resources with real WASI" do
    test "real file read/write operations", %{instance: instance, sandbox_dir: sandbox_dir} do
      # Open the output directory using its mapped name
      dir =
        call_sync(instance, ["test:filesystem/types", "open-directory"], ["output"])
        |> unwrap_result("Failed to open directory")

      # Create a real file
      file =
        call_sync(instance, ["test:filesystem/types", "[method]directory.create-file"], [
          dir,
          "test.txt"
        ])
        |> unwrap_result("Failed to create file")

      # Write real data
      data = "Hello from WASI!"

      written =
        call_sync(instance, ["test:filesystem/types", "[method]file-handle.write"], [
          file,
          :erlang.binary_to_list(data)
        ])
        |> unwrap_result("Failed to write to file")

      assert written == byte_size(data)

      # Verify file exists on host filesystem
      host_path = Path.join(sandbox_dir, "output/test.txt")
      assert File.exists?(host_path)
      assert File.read!(host_path) == "Hello from WASI!"

      # Clean up file handle
      call_sync(instance, ["test:filesystem/types", "[method]file-handle.close"], [file])
      |> unwrap_result("Failed to close file")
    end

    test "directory listing reflects real filesystem", %{
      instance: instance,
      sandbox_dir: sandbox_dir
    } do
      # Pre-create files on host
      work_dir = Path.join(sandbox_dir, "work")
      File.write!(Path.join(work_dir, "file1.txt"), "content1")
      File.write!(Path.join(work_dir, "file2.txt"), "content2")

      # Open directory from WASM using mapped name
      dir =
        call_sync(instance, ["test:filesystem/types", "open-directory"], ["work"])
        |> unwrap_result("Failed to open directory")

      # List should show real files
      entries =
        call_sync(instance, ["test:filesystem/types", "[method]directory.list-entries"], [dir])
        |> unwrap_result("Failed to list directory")

      assert "file1.txt" in entries
      assert "file2.txt" in entries
    end

    test "file operations are isolated between tests", %{
      instance: instance,
      sandbox_dir: sandbox_dir
    } do
      # Each test has its own sandbox - no conflicts
      refute File.exists?(Path.join(sandbox_dir, "output/other_test_file.txt"))

      # Create a file in this test's sandbox using mapped name
      dir =
        call_sync(instance, ["test:filesystem/types", "open-directory"], ["output"])
        |> unwrap_result("Failed to open directory")

      file =
        call_sync(instance, ["test:filesystem/types", "[method]directory.create-file"], [
          dir,
          "isolated_test.txt"
        ])
        |> unwrap_result("Failed to create file")

      data = "Isolated content"

      call_sync(instance, ["test:filesystem/types", "[method]file-handle.write"], [
        file,
        :erlang.binary_to_list(data)
      ])
      |> unwrap_result("Failed to write to file")

      # Verify it exists in this sandbox
      assert File.exists?(Path.join(sandbox_dir, "output/isolated_test.txt"))
    end

    test "read pre-populated files from input directory", %{
      instance: instance,
      sandbox_dir: _sandbox_dir
    } do
      # Input directory has pre-populated files from sandbox setup
      # Use mapped name
      dir =
        call_sync(instance, ["test:filesystem/types", "open-directory"], ["input"])
        |> unwrap_result("Failed to open directory")

      # Open existing file
      file =
        call_sync(instance, ["test:filesystem/types", "[method]directory.open-file"], [
          dir,
          "readme.txt"
        ])
        |> unwrap_result("Failed to open file")

      # Read content
      content =
        call_sync(instance, ["test:filesystem/types", "[method]file-handle.read"], [file, 100])
        |> unwrap_result("Failed to read file")

      # Convert byte list to string
      content_str = List.to_string(content)
      assert content_str == "Test file content"
    end

    test "seek operations work correctly", %{instance: instance, sandbox_dir: _sandbox_dir} do
      # Use mapped name
      dir =
        call_sync(instance, ["test:filesystem/types", "open-directory"], ["output"])
        |> unwrap_result("Failed to open directory")

      file =
        call_sync(instance, ["test:filesystem/types", "[method]directory.create-file"], [
          dir,
          "seek_test.txt"
        ])
        |> unwrap_result("Failed to create file")

      # Write some data
      data = "0123456789ABCDEF"

      call_sync(instance, ["test:filesystem/types", "[method]file-handle.write"], [
        file,
        :erlang.binary_to_list(data)
      ])
      |> unwrap_result("Failed to write to file")

      # Seek to position 5
      new_pos =
        call_sync(instance, ["test:filesystem/types", "[method]file-handle.seek"], [file, 5])
        |> unwrap_result("Failed to seek")

      assert new_pos == 5

      # Read from new position
      content =
        call_sync(instance, ["test:filesystem/types", "[method]file-handle.read"], [file, 5])
        |> unwrap_result("Failed to read after seek")

      content_str = List.to_string(content)
      assert content_str == "56789"
    end

    test "delete file operation", %{instance: instance, sandbox_dir: sandbox_dir} do
      work_dir = Path.join(sandbox_dir, "work")

      # Create a file on host first
      file_path = Path.join(work_dir, "to_delete.txt")
      File.write!(file_path, "Delete me")
      assert File.exists?(file_path)

      # Open directory from WASM using mapped name
      dir =
        call_sync(instance, ["test:filesystem/types", "open-directory"], ["work"])
        |> unwrap_result("Failed to open directory")

      # Delete the file
      call_sync(instance, ["test:filesystem/types", "[method]directory.delete-file"], [
        dir,
        "to_delete.txt"
      ])
      |> unwrap_result("Failed to delete file")

      # Verify file is deleted on host
      refute File.exists?(file_path)
    end

    test "error handling for non-existent files", %{instance: instance, sandbox_dir: _sandbox_dir} do
      # Use mapped name
      dir =
        call_sync(instance, ["test:filesystem/types", "open-directory"], ["work"])
        |> unwrap_result("Failed to open directory")

      # Try to open non-existent file
      result =
        call_sync(instance, ["test:filesystem/types", "[method]directory.open-file"], [
          dir,
          "non_existent.txt"
        ])

      assert match?({:ok, {:error, _}}, result)
    end

    test "error handling for non-existent directory", %{
      instance: instance,
      sandbox_dir: _sandbox_dir
    } do
      # Try to open non-existent directory
      result =
        call_sync(instance, ["test:filesystem/types", "open-directory"], ["non_existent_dir"])

      # The open-directory function returns Ok(Directory) even for non-existent dirs
      # but operations on it will fail
      assert match?({:ok, _}, result)
    end
  end

  describe "resource lifecycle" do
    test "resources are properly managed", %{instance: instance, sandbox_dir: sandbox_dir} do
      # Create multiple resources using mapped name
      dir =
        call_sync(instance, ["test:filesystem/types", "open-directory"], ["output"])
        |> unwrap_result("Failed to open directory")

      # Create multiple files
      files =
        for i <- 1..5 do
          file =
            call_sync(instance, ["test:filesystem/types", "[method]directory.create-file"], [
              dir,
              "resource_test_#{i}.txt"
            ])
            |> unwrap_result("Failed to create file #{i}")

          # Write to file
          call_sync(instance, ["test:filesystem/types", "[method]file-handle.write"], [
            file,
            :erlang.binary_to_list("Content #{i}")
          ])
          |> unwrap_result("Failed to write to file #{i}")

          file
        end

      # Close all files
      for file <- files do
        call_sync(instance, ["test:filesystem/types", "[method]file-handle.close"], [file])
        |> unwrap_result("Failed to close file")
      end

      # Verify files exist on filesystem
      for i <- 1..5 do
        path = Path.join(sandbox_dir, "output/resource_test_#{i}.txt")
        assert File.exists?(path)
        assert File.read!(path) == "Content #{i}"
      end
    end
  end
end
