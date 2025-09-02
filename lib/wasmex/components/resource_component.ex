defmodule Wasmex.Components.ResourceComponent do
  @moduledoc """
  Enhanced resource component system that provides ComponentServer-like functionality for resources.

  This module provides a complete solution for working with WASM resources, including:
  - Automatic method wrapper generation from WIT definitions
  - Integration with ResourceManager for WASM interop
  - Clean GenServer-based API
  - Support for both host-defined and WASM-exported resources

  ## Basic Usage

  ```elixir
  defmodule MyApp.CounterResource do
    use Wasmex.Components.ResourceComponent,
      wit: "path/to/counter.wit",
      resource: "counter"
    
    @impl true
    def init(initial_value) do
      # Initialize your resource state
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
  end

  # Start and use the resource
  {:ok, pid} = MyApp.CounterResource.start_link(42)

  # Methods return {:ok, result} or {:error, reason}
  {:ok, 43} = MyApp.CounterResource.increment(pid)
  {:ok, 43} = MyApp.CounterResource.get_value(pid)

  # Error handling
  case MyApp.CounterResource.increment(pid) do
    {:ok, new_value} -> IO.puts("New value: \#{new_value}")
    {:error, reason} -> IO.puts("Failed: \#{reason}")
  end
  ```

  ## With WASM Components

  ```elixir
  # Create a resource that can be passed to WASM
  {:ok, store} = Wasmex.Components.Store.new()
  {:ok, handle} = MyApp.CounterResource.create_for_wasm(store, 0)

  # Pass to WASM component that expects a counter resource
  Wasmex.Components.Instance.call_function(instance, "process-counter", [handle])
  ```
  """

  defmacro __using__(opts) do
    wit_path = Keyword.get(opts, :wit)
    resource_name = Keyword.get(opts, :resource)

    base_implementation =
      quote do
        # Use GenServer without declaring ResourceBehaviour to avoid conflicts
        use GenServer
        require Logger

        # Client API

        @doc """
        Starts the resource as a standalone GenServer.
        """
        def start_link(args, opts \\ []) do
          GenServer.start_link(__MODULE__, {:standalone, args}, opts)
        end

        @doc """
        Creates a resource that can be passed to WASM components.

        This integrates with ResourceManager to create a handle that WASM can use.
        """
        def create_for_wasm(store, args, opts \\ []) do
          Wasmex.Components.ResourceManager.create_resource(store, __MODULE__, args, opts)
        end

        @doc """
        Stops the resource gracefully.
        """
        def stop(pid, reason \\ :normal, timeout \\ :infinity) do
          GenServer.stop(pid, reason, timeout)
        end

        # ResourceBehaviour-like callbacks (without the @behaviour declaration)

        def type_name, do: unquote(resource_name || "resource")

        # GenServer callbacks

        # GenServer init implementation - DO NOT OVERRIDE
        @impl GenServer
        def init({:standalone, args}) do
          case resource_init(args) do
            {:ok, state} ->
              Process.put(:resource_type, type_name())
              {:ok, wrap_state(state)}

            {:error, reason} ->
              {:stop, reason}
          end
        end

        @impl GenServer
        def init(args) do
          # When started via ResourceManager
          resource_init(args)
        end

        # Internal function that calls user's init
        defp resource_init(args) do
          apply(__MODULE__, :init_resource, [args])
        end

        # Resource initialization - override this in your module
        def init_resource(_args) do
          raise "init_resource/1 must be implemented by the resource module"
        end

        defoverridable init_resource: 1

        @impl GenServer
        def handle_call({:method, method, params}, _from, state) do
          {_wrapped_state, unwrapped_state} = unwrap_state(state)

          # Call handle_method and handle all possible return values
          result = handle_method(method, params, unwrapped_state)

          case result do
            {:reply, reply_value, new_state} ->
              {:reply, {:ok, reply_value}, wrap_state(new_state)}

            {:noreply, new_state} ->
              {:reply, {:ok, nil}, wrap_state(new_state)}

            {:error, reason, new_state} ->
              {:reply, {:error, reason}, wrap_state(new_state)}

            _ ->
              Logger.error("Invalid return from handle_method: #{inspect(result)}")
              {:reply, {:error, "Invalid method handler return"}, state}
          end
        end

        @impl GenServer
        def terminate(reason, state) do
          {_wrapped, unwrapped} = unwrap_state(state)
          on_terminate(reason, unwrapped)
        end

        # Default on_terminate - override if you need cleanup
        def on_terminate(_reason, _state) do
          :ok
        end

        defoverridable on_terminate: 2

        # Resource init callback - must be implemented by user
        def init(_args) do
          raise "init/1 must be implemented by the resource module"
        end

        # Make init overridable so user can implement it
        defoverridable init: 1

        # Helper functions

        defp wrap_state(state) do
          %{
            module: __MODULE__,
            state: state,
            type_name: type_name()
          }
        end

        defp unwrap_state(%{state: state} = wrapped) do
          {wrapped, state}
        end

        defp unwrap_state(state) do
          {wrap_state(state), state}
        end

        defp call_method_internal(pid, method, params, timeout \\ 5000) do
          GenServer.call(pid, {:method, method, params}, timeout)
        end

        # Optional callbacks
        defoverridable type_name: 0
      end

    method_wrappers =
      if wit_path && resource_name do
        # Generate method wrappers from WIT file
        methods = parse_wit_resource_methods(wit_path, resource_name)

        for {method_name, param_info} <- methods do
          function_name = method_name |> String.replace("-", "_") |> String.to_atom()

          case param_info do
            {:arity, arity} ->
              arglist = Macro.generate_arguments(arity, __MODULE__)

              quote do
                def unquote(function_name)(pid, unquote_splicing(arglist)) do
                  call_method_internal(pid, unquote(method_name), [unquote_splicing(arglist)])
                end
              end

            {:params, param_specs} ->
              # Generate with proper parameter names if available
              param_names =
                Enum.map(param_specs, fn {name, _type} ->
                  Macro.var(String.to_atom(String.replace(name, "-", "_")), __MODULE__)
                end)

              quote do
                def unquote(function_name)(pid, unquote_splicing(param_names)) do
                  call_method_internal(pid, unquote(method_name), [unquote_splicing(param_names)])
                end
              end
          end
        end
      else
        []
      end

    [base_implementation, method_wrappers]
  end

  @doc false
  def parse_wit_resource_methods(wit_path, resource_name) do
    wit_contents = File.read!(wit_path)

    # Find the resource definition
    resource_pattern = ~r/resource\s+#{Regex.escape(resource_name)}\s*\{([^}]+)\}/s

    case Regex.run(resource_pattern, wit_contents) do
      [_, resource_body] ->
        # Parse each method
        method_pattern = ~r/([a-z][a-z0-9-]*)\s*:\s*func\s*\(([^)]*)\)(?:\s*->\s*(.+?))?(?:;|$)/m

        Regex.scan(method_pattern, resource_body)
        |> Enum.map(fn
          [_, method_name, "", _] ->
            {method_name, {:arity, 0}}

          [_, method_name, params, _] ->
            # Parse parameters
            param_list = parse_wit_params(params)

            if Enum.all?(param_list, &match?({_name, _type}, &1)) do
              {method_name, {:params, param_list}}
            else
              {method_name, {:arity, length(param_list)}}
            end
        end)

      nil ->
        []
    end
  end

  defp parse_wit_params(params_string) do
    params_string
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn param ->
      case String.split(param, ":", parts: 2) do
        [name, type] -> {String.trim(name), String.trim(type)}
        [_] -> :anonymous
      end
    end)
  end
end
