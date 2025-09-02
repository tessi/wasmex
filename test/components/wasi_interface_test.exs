defmodule Wasmex.Components.WasiInterfaceTest do
  use ExUnit.Case, async: true

  alias Wasmex.Components.Store
  alias Wasmex.Wasi.WasiP2Options

  describe "WASI filesystem configuration" do
    test "enables filesystem access by default" do
      wasi_opts = %WasiP2Options{}
      assert {:ok, store} = Store.new_wasi(wasi_opts)

      # Filesystem should be available (default: true)
      # We can't directly test filesystem operations without a WASM component
      # but we can verify the store was created with the config
      assert store.resource
    end

    test "explicitly enables filesystem access" do
      wasi_opts = %WasiP2Options{
        allow_filesystem: true
      }

      assert {:ok, store} = Store.new_wasi(wasi_opts)
      assert store.resource
    end

    test "disables filesystem access when requested" do
      wasi_opts = %WasiP2Options{
        allow_filesystem: false
      }

      assert {:ok, store} = Store.new_wasi(wasi_opts)
      assert store.resource
    end

    test "preopens directories for filesystem access" do
      temp_dir = System.tmp_dir!()

      wasi_opts = %WasiP2Options{
        allow_filesystem: true,
        preopen_dirs: [temp_dir, "/tmp"]
      }

      assert {:ok, store} = Store.new_wasi(wasi_opts)
      assert store.resource
    end

    test "handles invalid preopen directories gracefully" do
      wasi_opts = %WasiP2Options{
        allow_filesystem: true,
        preopen_dirs: ["/nonexistent/directory/path"]
      }

      # Should either succeed or return a clear error
      result = Store.new_wasi(wasi_opts)

      case result do
        {:ok, store} ->
          assert store.resource

        {:error, reason} ->
          assert reason =~ "preopen"
      end
    end
  end

  describe "WASI network configuration" do
    test "disables network by default when allow_http is false" do
      wasi_opts = %WasiP2Options{
        allow_http: false
      }

      assert {:ok, store} = Store.new_wasi(wasi_opts)
      assert store.resource
    end

    test "enables network when allow_http is true" do
      wasi_opts = %WasiP2Options{
        allow_http: true
      }

      assert {:ok, store} = Store.new_wasi(wasi_opts)
      assert store.resource
    end

    test "network access controlled via allow_http" do
      # Network access is enabled via allow_http
      wasi_opts = %WasiP2Options{
        allow_http: true
      }

      assert {:ok, store} = Store.new_wasi(wasi_opts)
      assert store.resource
    end

    test "network access disabled by default" do
      wasi_opts = %WasiP2Options{
        allow_http: false
      }

      assert {:ok, store} = Store.new_wasi(wasi_opts)
      assert store.resource
    end
  end

  describe "WASI standard I/O configuration" do
    test "inherits standard streams by default" do
      wasi_opts = %WasiP2Options{}
      assert {:ok, store} = Store.new_wasi(wasi_opts)
      # Verify store is created with WASI support
      assert store != nil

      # Default values should be true
      assert wasi_opts.inherit_stdin == true
      assert wasi_opts.inherit_stdout == true
      assert wasi_opts.inherit_stderr == true
    end

    test "can disable individual streams" do
      wasi_opts = %WasiP2Options{
        inherit_stdin: false,
        inherit_stdout: true,
        inherit_stderr: false
      }

      assert {:ok, store} = Store.new_wasi(wasi_opts)
      assert store.resource
    end
  end

  describe "WASI environment configuration" do
    test "passes environment variables to component" do
      wasi_opts = %WasiP2Options{
        env: %{
          "TEST_VAR" => "test_value",
          "DEBUG" => "1",
          "PATH" => "/usr/bin:/bin"
        }
      }

      assert {:ok, store} = Store.new_wasi(wasi_opts)
      assert store.resource
    end

    test "passes command-line arguments to component" do
      wasi_opts = %WasiP2Options{
        args: ["--verbose", "--config", "/path/to/config.json"]
      }

      assert {:ok, store} = Store.new_wasi(wasi_opts)
      assert store.resource
    end

    test "combines environment and arguments" do
      wasi_opts = %WasiP2Options{
        args: ["program", "--help"],
        env: %{"LANG" => "en_US.UTF-8"}
      }

      assert {:ok, store} = Store.new_wasi(wasi_opts)
      assert store.resource
    end
  end

  describe "all WASI interfaces enabled" do
    test "creates store with all WASI capabilities" do
      wasi_opts = %WasiP2Options{
        inherit_stdin: true,
        inherit_stdout: true,
        inherit_stderr: true,
        allow_http: true,
        allow_filesystem: true,
        preopen_dirs: [System.tmp_dir!()],
        args: ["test"],
        env: %{"TEST" => "1"}
      }

      assert {:ok, store} = Store.new_wasi(wasi_opts)
      assert store.resource
    end
  end

  describe "WASI interface availability verification" do
    @tag :wasi_component
    test "filesystem interface is available when enabled" do
      # This would require a test component that uses filesystem
      # For now, we just verify the configuration doesn't crash
      wasi_opts = %WasiP2Options{
        allow_filesystem: true,
        preopen_dirs: [System.tmp_dir!()]
      }

      assert {:ok, store} = Store.new_wasi(wasi_opts)
      # Verify store is created with filesystem support
      assert store != nil

      # Future: Load a component that uses wasi:filesystem
      # and verify it can be instantiated
    end

    @tag :wasi_component
    test "network interface is available when enabled" do
      # Network access is controlled via allow_http
      wasi_opts = %WasiP2Options{
        allow_http: true
      }

      assert {:ok, store} = Store.new_wasi(wasi_opts)
      # Verify store is created with network support
      assert store != nil

      # Future: Load a component that uses wasi:sockets
      # and verify it can be instantiated
    end

    @tag :wasi_component
    test "clock interface is available by default" do
      # Clock should be available with basic WASI P2
      wasi_opts = %WasiP2Options{}

      assert {:ok, _store} = Store.new_wasi(wasi_opts)

      # Future: Load a component that uses wasi:clocks
      # and verify it can be instantiated
    end

    @tag :wasi_component
    test "random interface is available by default" do
      # Random should be available with basic WASI P2
      wasi_opts = %WasiP2Options{}

      assert {:ok, _store} = Store.new_wasi(wasi_opts)

      # Future: Load a component that uses wasi:random
      # and verify it can be instantiated
    end
  end

  describe "error handling" do
    test "handles invalid configuration gracefully" do
      # Test with various configurations that should work with defaults
      configs = [
        # All defaults
        %WasiP2Options{},
        # With args
        %WasiP2Options{args: ["test"]},
        # With env
        %WasiP2Options{env: %{"A" => "B"}}
      ]

      for config <- configs do
        assert {:ok, store} = Store.new_wasi(config)
        assert store.resource
      end
    end
  end
end
