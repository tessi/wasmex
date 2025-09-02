defmodule Wasmex.Components.ResourceComponentServer do
  @moduledoc """
  A macro for creating GenServer-based resources with automatic method generation from WIT files.

  This module provides a ComponentServer-like interface for resources, automatically generating
  wrapper functions for all resource methods defined in the WIT file.

  ## Usage

  Given a WIT file with a resource definition:

  ```wit
  package example:counter;

  interface types {
    resource counter {
      constructor(initial: u32);
      increment: func() -> u32;
      get-value: func() -> u32;
      reset: func(value: u32);
    }
  }
  ```

  You can create a resource server like this:

  ```elixir
  defmodule MyApp.Counter do
    use Wasmex.Components.ResourceComponentServer,
      wit: "path/to/counter.wit",
      resource: "counter"
    
    # Implement the actual logic for each method
    @impl true
    def init(initial_value) do
      {:ok, %{value: initial_value}}
    end
    
    @impl true
    def handle_method("increment", [], state) do
      new_value = state.value + 1
      {:reply, new_value, %{state | value: new_value}}
    end
    
    @impl true
    def handle_method("get-value", [], state) do
      {:reply, state.value, state}
    end
    
    @impl true
    def handle_method("reset", [value], state) do
      {:noreply, %{state | value: value}}
    end
  end
  ```

  This will automatically generate the following functions:

  ```elixir
  # Start the resource
  {:ok, pid} = MyApp.Counter.start_link(42)

  # Generated method wrappers return {:ok, result} or {:error, reason}
  {:ok, 43} = MyApp.Counter.increment(pid)
  {:ok, 43} = MyApp.Counter.get_value(pid)
  {:ok, nil} = MyApp.Counter.reset(pid, 0)

  # Error handling
  case MyApp.Counter.increment(pid) do
    {:ok, new_value} -> IO.puts("Incremented to \#{new_value}")
    {:error, reason} -> IO.puts("Failed: \#{reason}")
  end
  ```

  ## Options

  * `:wit` - Path to the WIT file containing the resource definition
  * `:resource` - Name of the resource in the WIT file
  * `:interface` - Optional interface name if the resource is in an interface (default: "types")
  """

  defmacro __using__(opts) do
    wit_path = Keyword.get(opts, :wit)
    resource_name = Keyword.get(opts, :resource)
    interface_name = Keyword.get(opts, :interface, "types")

    if wit_path && resource_name do
      genserver_setup =
        quote do
          # Use GenServer without declaring ResourceBehaviour to avoid conflicts
          use GenServer

          def start_link(args, opts \\ []) do
            GenServer.start_link(__MODULE__, args, opts)
          end

          def type_name, do: unquote(resource_name)

          # GenServer init that delegates to user's init
          @impl GenServer
          def init(args) do
            # Call the user's init/1 function
            case apply(__MODULE__, :init, [args]) do
              {:ok, state} ->
                Process.put(:resource_module, __MODULE__)
                Process.put(:resource_type, unquote(resource_name))
                {:ok, %{module: __MODULE__, state: state, type_name: unquote(resource_name)}}

              {:error, reason} ->
                {:stop, {:error, reason}}
            end
          end

          # Default init that raises - user must override
          def init(_args) do
            raise "init/1 must be implemented"
          end

          defoverridable init: 1

          @impl GenServer
          def handle_call(
                {:method, method, params},
                _from,
                %{module: module, state: state} = server_state
              ) do
            case module.handle_method(method, params, state) do
              {:reply, result, new_state} ->
                {:reply, {:ok, result}, %{server_state | state: new_state}}

              {:error, reason, new_state} ->
                {:reply, {:error, reason}, %{server_state | state: new_state}}

              {:noreply, new_state} ->
                {:reply, {:ok, nil}, %{server_state | state: new_state}}

              invalid ->
                {:reply, {:error, "Invalid method handler return"}, server_state}
            end
          end

          @impl GenServer
          def terminate(reason, %{module: module, state: state}) do
            module.on_terminate(reason, state)
          end

          def terminate(_reason, _state), do: :ok

          # Default on_terminate - override if you need cleanup
          def on_terminate(_reason, _state) do
            :ok
          end

          defoverridable on_terminate: 2

          # Internal helper for method calls
          defp call_method(pid, method, params, timeout \\ 5000) do
            GenServer.call(pid, {:method, method, params}, timeout)
          end
        end

      # Parse WIT file and generate method wrappers
      methods =
        if wit_path do
          parse_resource_methods(wit_path, interface_name, resource_name)
        else
          []
        end

      method_wrappers =
        for {method_name, arity} <- methods do
          # Convert WIT method names to Elixir function names
          function_name = method_name |> String.replace("-", "_") |> String.to_atom()
          arglist = Macro.generate_arguments(arity, __MODULE__)

          quote do
            def unquote(function_name)(pid, unquote_splicing(arglist)) do
              call_method(pid, unquote(method_name), [unquote_splicing(arglist)])
            end
          end
        end

      [genserver_setup, method_wrappers]
    else
      quote do
        # Use GenServer without declaring ResourceBehaviour to avoid conflicts
        use GenServer

        def start_link(args, opts \\ []) do
          GenServer.start_link(__MODULE__, args, opts)
        end

        # Default implementations - override these in your module
        def type_name, do: "unknown"

        @impl GenServer
        def init(args) do
          case apply(__MODULE__, :init, [args]) do
            {:ok, state} ->
              {:ok, %{module: __MODULE__, state: state, type_name: type_name()}}

            {:error, reason} ->
              {:stop, {:error, reason}}
          end
        end

        # Default init that raises - user must override
        def init(_args) do
          raise "init/1 must be implemented"
        end

        defoverridable init: 1

        @impl GenServer
        def handle_call(
              {:method, method, params},
              _from,
              %{module: module, state: state} = server_state
            ) do
          case module.handle_method(method, params, state) do
            {:reply, result, new_state} ->
              {:reply, {:ok, result}, %{server_state | state: new_state}}

            {:error, reason, new_state} ->
              {:reply, {:error, reason}, %{server_state | state: new_state}}

            {:noreply, new_state} ->
              {:reply, {:ok, nil}, %{server_state | state: new_state}}
          end
        end

        @impl GenServer
        def terminate(reason, %{module: module, state: state}) do
          if function_exported?(module, :on_terminate, 2) do
            module.on_terminate(reason, state)
          else
            :ok
          end
        end

        def terminate(_reason, _state), do: :ok
      end
    end
  end

  @doc false
  def parse_resource_methods(wit_path, _interface_name, resource_name) do
    # Read and parse the WIT file
    wit_contents = File.read!(wit_path)

    # Find the resource block
    resource_regex = ~r/resource\s+#{Regex.escape(resource_name)}\s*\{([^}]+)\}/s

    case Regex.run(resource_regex, wit_contents) do
      [_, resource_body] ->
        # Parse methods from the resource body
        # Match function definitions like: "increment: func() -> u32"
        method_regex = ~r/([a-z-]+):\s*func\s*\(([^)]*)\)/

        Regex.scan(method_regex, resource_body)
        |> Enum.map(fn [_, method_name, params] ->
          # Count parameters (simplified - doesn't handle complex types)
          param_count =
            if params == "" do
              0
            else
              params |> String.split(",") |> length()
            end

          {method_name, param_count}
        end)

      nil ->
        # If we can't parse the WIT file, return an empty list
        # In production, you'd want to use Wasmex.Native to parse this properly
        []
    end
  end
end
