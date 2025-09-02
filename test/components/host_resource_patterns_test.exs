defmodule Wasmex.Components.HostResourcePatternsTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests demonstrating common patterns for implementing host resources
  that can be exposed to WebAssembly components.
  
  These examples show how to create Elixir GenServers that act as resources
  for WASM components to interact with host capabilities.
  """

  describe "Host Resources (90% of use cases)" do
    test "simple host resource for WASM to use" do
      defmodule Logger do
        use GenServer

        def start_link(level) do
          GenServer.start_link(__MODULE__, level)
        end

        def init(level) do
          {:ok, %{level: level, messages: []}}
        end

        def handle_call({:method, "log", [msg]}, _from, state) do
          new_state = %{state | messages: [msg | state.messages]}
          {:reply, {:ok, :logged}, new_state}
        end

        def handle_call({:method, "get_all", []}, _from, state) do
          {:reply, {:ok, Enum.reverse(state.messages)}, state}
        end
      end

      # This is what WASM would do
      {:ok, logger} = Logger.start_link(:info)
      assert {:ok, :logged} = GenServer.call(logger, {:method, "log", ["Hello"]})
      assert {:ok, :logged} = GenServer.call(logger, {:method, "log", ["World"]})
      assert {:ok, ["Hello", "World"]} = GenServer.call(logger, {:method, "get_all", []})
      GenServer.stop(logger)
    end

    test "resource with state management" do
      defmodule Database do
        use GenServer

        def start_link(name) do
          GenServer.start_link(__MODULE__, name)
        end

        def init(name) do
          {:ok, %{name: name, queries: []}}
        end

        def handle_call({:method, "query", [sql]}, _from, state) do
          result = "Result for: #{sql}"
          new_state = %{state | queries: [sql | state.queries]}
          {:reply, {:ok, result}, new_state}
        end

        def handle_call({:method, "stats", []}, _from, state) do
          {:reply, {:ok, %{name: state.name, query_count: length(state.queries)}}, state}
        end
      end

      {:ok, db} = Database.start_link("test_db")
      assert {:ok, "Result for: SELECT 1"} = GenServer.call(db, {:method, "query", ["SELECT 1"]})

      assert {:ok, %{name: "test_db", query_count: 1}} =
               GenServer.call(db, {:method, "stats", []})

      GenServer.stop(db)
    end
  end

  describe "WIT parsing for wrapper generation" do
    test "parses resource methods from WIT" do
      wit = """
      resource filesystem {
        read: func(path: string) -> string;
        write: func(path: string, data: string);
        exists: func(path: string) -> bool;
      }
      """

      path = Path.join(System.tmp_dir!(), "fs_#{:rand.uniform(100_000)}.wit")
      File.write!(path, wit)

      methods =
        Wasmex.Components.ResourceComponentServer.parse_resource_methods(path, nil, "filesystem")

      assert {"read", 1} in methods
      assert {"write", 2} in methods
      assert {"exists", 1} in methods

      File.rm(path)
    end
  end

  describe "Integration with OTP" do
    test "resources work in supervision trees" do
      defmodule Cache do
        use GenServer

        def start_link(opts) do
          GenServer.start_link(__MODULE__, opts[:name] || "cache")
        end

        def init(name) do
          {:ok, %{name: name, data: %{}}}
        end

        def handle_call({:method, "set", [key, value]}, _from, state) do
          new_state = %{state | data: Map.put(state.data, key, value)}
          {:reply, {:ok, :stored}, new_state}
        end

        def handle_call({:method, "get", [key]}, _from, state) do
          {:reply, {:ok, Map.get(state.data, key)}, state}
        end
      end

      # Supervise the resource
      children = [{Cache, name: "test_cache"}]
      {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)

      # Get the cache process
      [{_, cache_pid, _, _}] = Supervisor.which_children(sup)

      # Use it like a resource
      assert {:ok, :stored} = GenServer.call(cache_pid, {:method, "set", ["key1", "value1"]})
      assert {:ok, "value1"} = GenServer.call(cache_pid, {:method, "get", ["key1"]})

      Supervisor.stop(sup)
    end
  end

  describe "Real-world patterns" do
    test "file system resource for WASM" do
      defmodule FileSystem do
        use GenServer

        def start_link(root) do
          GenServer.start_link(__MODULE__, root)
        end

        def init(root) do
          {:ok, %{root: root}}
        end

        # WASM would call these methods
        def handle_call({:method, "read", [_path]}, _from, state) do
          # In real impl, would read from Path.join(state.root, _path)
          {:reply, {:ok, "file contents"}, state}
        end

        def handle_call({:method, "write", [_path, _data]}, _from, state) do
          # In real impl, would write to Path.join(state.root, _path)
          {:reply, {:ok, :written}, state}
        end
      end

      {:ok, fs} = FileSystem.start_link("/tmp")
      assert {:ok, "file contents"} = GenServer.call(fs, {:method, "read", ["test.txt"]})
      assert {:ok, :written} = GenServer.call(fs, {:method, "write", ["test.txt", "data"]})
      GenServer.stop(fs)
    end

    test "HTTP client resource for WASM" do
      defmodule HttpClient do
        use GenServer

        def start_link(_opts) do
          GenServer.start_link(__MODULE__, %{})
        end

        def init(_) do
          {:ok, %{request_count: 0}}
        end

        def handle_call({:method, "get", [url]}, _from, state) do
          # In real impl, would make HTTP request
          result = "Response from #{url}"
          new_state = %{state | request_count: state.request_count + 1}
          {:reply, {:ok, result}, new_state}
        end

        def handle_call({:method, "stats", []}, _from, state) do
          {:reply, {:ok, state.request_count}, state}
        end
      end

      {:ok, http} = HttpClient.start_link([])

      assert {:ok, "Response from https://api.example.com"} =
               GenServer.call(http, {:method, "get", ["https://api.example.com"]})

      assert {:ok, 1} = GenServer.call(http, {:method, "stats", []})
      GenServer.stop(http)
    end
  end
end
