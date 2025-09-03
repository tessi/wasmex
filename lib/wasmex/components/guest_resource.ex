defmodule Wasmex.Components.GuestResource do
  @moduledoc """
  Macro for generating client modules for guest resources.

  This macro parses a WIT file at compile time and generates
  a complete GenServer implementation for interacting with WASM guest resources.

  ## Example

      defmodule MyApp.Counter do
        use Wasmex.Components.GuestResource,
          wit: "path/to/counter.wit",
          resource: "counter"
      end
      
  This generates:
  - `MyApp.Counter.start_link/2` - Creates a new resource instance
  - `MyApp.Counter.increment/1` - Calls the increment method
  - `MyApp.Counter.get_value/1` - Calls the get-value method
  - `MyApp.Counter.reset/2` - Calls the reset method with an argument

  Each generated module is a complete GenServer implementation.
  """

  defmacro __using__(opts) do
    wit_path = Keyword.fetch!(opts, :wit)
    resource_name = Keyword.fetch!(opts, :resource)

    # Parse WIT file at compile time
    resource_info = parse_wit_at_compile_time(wit_path, resource_name)

    # Generate the complete GenServer module
    quote do
      use GenServer
      require Logger

      # Internal state structure
      defmodule State do
        @moduledoc false
        defstruct [:instance, :resource_handle, :resource_type, :interface_path]
      end

      unquote_splicing(generate_public_api(resource_info))
      unquote_splicing(generate_genserver_callbacks(resource_info))
      unquote_splicing(generate_private_helpers())
    end
  end

  defp parse_wit_at_compile_time(wit_path, resource_name) do
    # Read and parse WIT file at compile time
    case Wasmex.Components.GuestResource.Discovery.get_resource_from_wit(wit_path, resource_name) do
      {:ok, resource_info} ->
        # Generate paths for the resource
        paths = Wasmex.Components.GuestResource.Discovery.generate_paths(resource_info)
        Map.merge(resource_info, paths)

      {:error, reason} ->
        raise CompileError,
          description: "Failed to parse WIT file or find resource: #{inspect(reason)}"
    end
  end

  defp generate_public_api(resource_info) do
    [
      generate_start_link(),
      generate_child_spec(),
      generate_methods(resource_info)
    ]
  end

  defp generate_start_link() do
    quote do
      @doc """
      Starts a new resource process.

      ## Parameters
        * `instance` - The WASM component instance
        * `args` - Constructor arguments
        * `opts` - GenServer options (e.g., `:name`)

      ## Returns
        * `{:ok, pid}` - The resource process
        * `{:error, reason}` - If creation failed
      """
      def start_link(instance, args \\ [], opts \\ []) do
        {name_opts, init_opts} = Keyword.split(opts, [:name])
        GenServer.start_link(__MODULE__, {instance, args, init_opts}, name_opts)
      end
    end
  end

  defp generate_child_spec() do
    quote do
      @doc """
      Returns a child specification for supervision.
      """
      def child_spec([instance, args, opts]) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [instance, args, opts]},
          type: :worker,
          restart: :permanent,
          shutdown: 5000
        }
      end

      def child_spec([instance, args]) do
        child_spec([instance, args, []])
      end
    end
  end

  defp generate_methods(resource_info) do
    resource_info.methods
    |> Enum.reject(fn {name, _, _} -> name == :constructor end)
    |> Enum.map(fn {method_name, arity, has_return} ->
      generate_method(method_name, arity, has_return)
    end)
  end

  defp generate_method(method_name, arity, has_return) do
    # Convert method name to Elixir function name
    func_name = method_name_to_function(method_name)

    # The arity is now the actual parameter count (self is not included)
    param_count = arity

    cond do
      param_count == 0 ->
        # No parameters except self
        quote do
          @doc """
          Calls the `#{unquote(method_name)}` method on the resource.

          ## Parameters
            * `resource` - The resource process or name

          ## Returns
            * #{unquote(return_doc(has_return))}
          """
          def unquote(func_name)(resource) do
            GenServer.call(resource, {:call_method, unquote(Atom.to_string(method_name)), []})
          end

          @doc false
          def unquote(func_name)(resource, timeout) when is_integer(timeout) do
            GenServer.call(
              resource,
              {:call_method, unquote(Atom.to_string(method_name)), []},
              timeout
            )
          end
        end

      param_count == 1 ->
        # Single parameter
        quote do
          @doc """
          Calls the `#{unquote(method_name)}` method on the resource.

          ## Parameters
            * `resource` - The resource process or name
            * `arg` - The method argument

          ## Returns
            * #{unquote(return_doc(has_return))}
          """
          def unquote(func_name)(resource, arg) do
            GenServer.call(resource, {:call_method, unquote(Atom.to_string(method_name)), [arg]})
          end

          @doc false
          def unquote(func_name)(resource, arg, timeout) when is_integer(timeout) do
            GenServer.call(
              resource,
              {:call_method, unquote(Atom.to_string(method_name)), [arg]},
              timeout
            )
          end
        end

      true ->
        # Multiple parameters
        params = Enum.map(1..param_count, fn i -> {:"arg#{i}", [], nil} end)

        quote do
          @doc """
          Calls the `#{unquote(method_name)}` method on the resource.

          ## Parameters
            * `resource` - The resource process or name
            * `args` - List of method arguments

          ## Returns
            * #{unquote(return_doc(has_return))}
          """
          def unquote(func_name)(resource, unquote_splicing(params)) do
            GenServer.call(
              resource,
              {:call_method, unquote(Atom.to_string(method_name)), [unquote_splicing(params)]}
            )
          end

          @doc false
          def unquote(func_name)(resource, unquote_splicing(params), timeout)
              when is_integer(timeout) do
            GenServer.call(
              resource,
              {:call_method, unquote(Atom.to_string(method_name)), [unquote_splicing(params)]},
              timeout
            )
          end
        end
    end
  end

  defp generate_genserver_callbacks(resource_info) do
    [
      quote do
        @impl GenServer
        def init({instance, args, opts}) do
          timeout = Keyword.get(opts, :timeout, 5000)
          interface_path = Keyword.get(opts, :interface, unquote(resource_info.interface_path))

          case __create_resource__(
                 instance,
                 unquote(resource_info.constructor_path),
                 args,
                 timeout
               ) do
            {:ok, resource_handle} ->
              state = %State{
                instance: instance,
                resource_handle: resource_handle,
                resource_type: unquote(resource_info.name),
                interface_path: interface_path
              }

              Process.put(:guest_resource_type, unquote(resource_info.name))
              Process.put(:guest_resource_instance, instance)

              {:ok, state}

            {:error, reason} ->
              {:stop, {:resource_creation_failed, reason}}
          end
        end

        @impl GenServer
        def handle_call({:call_method, method, args}, _from, state) do
          %State{instance: instance, resource_handle: handle, interface_path: interface_path} =
            state

          method_name = __normalize_method_name__(method)

          try do
            result =
              Wasmex.Components.Instance.call(
                instance,
                handle,
                method_name,
                args,
                interface: interface_path
              )

            {:reply, result, state}
          rescue
            error ->
              Logger.error("Error calling method #{method_name}: #{inspect(error)}")
              {:reply, {:error, {:method_call_failed, error}}, state}
          catch
            :exit, reason ->
              Logger.error("Instance died during method call: #{inspect(reason)}")
              {:stop, {:instance_died, reason}, {:error, :instance_died}, state}
          end
        end

        @impl GenServer
        def terminate(_reason, _state) do
          # Resources are automatically dropped when the instance is destroyed
          :ok
        end
      end
    ]
  end

  defp generate_private_helpers() do
    [
      quote do
        defp __create_resource__(instance, resource_path, args, timeout) do
          Wasmex.Components.Instance.new_resource(
            instance,
            resource_path,
            args,
            timeout
          )
        end

        defp __normalize_method_name__(method) when is_atom(method) do
          method
          |> Atom.to_string()
          |> String.replace("_", "-")
        end

        defp __normalize_method_name__(method) when is_binary(method) do
          method
        end
      end
    ]
  end

  defp method_name_to_function(method_name) when is_atom(method_name) do
    method_name
    |> Atom.to_string()
    |> String.replace("-", "_")
    |> String.to_atom()
  end

  defp return_doc(true), do: "`{:ok, result}` on success, `{:error, reason}` on failure"
  defp return_doc(false), do: "`:ok` on success, `{:error, reason}` on failure"

  @doc """
  Creates a module at runtime from a WIT file.

  This allows dynamic generation of resource clients without compile-time macros.

  ## Parameters
    * `module_name` - The name for the generated module
    * `wit_path` - Path to the WIT file
    * `resource_name` - Name of the resource in the WIT file

  ## Returns
    * `{:ok, module}` - The generated module
    * `{:error, reason}` - If generation fails
  """
  def create_module(module_name, wit_path, resource_name) do
    case Wasmex.Components.GuestResource.Discovery.get_resource_from_wit(wit_path, resource_name) do
      {:ok, resource_info} ->
        paths = Wasmex.Components.GuestResource.Discovery.generate_paths(resource_info)
        resource_info = Map.merge(resource_info, paths)

        # Generate module code
        module_ast =
          quote do
            use GenServer
            require Logger

            defmodule State do
              @moduledoc false
              defstruct [:instance, :resource_handle, :resource_type, :interface_path]
            end

            unquote_splicing(generate_public_api(resource_info))
            unquote_splicing(generate_genserver_callbacks(resource_info))
            unquote_splicing(generate_private_helpers())
          end

        # Create the module dynamically
        Module.create(module_name, module_ast, Macro.Env.location(__ENV__))
        {:ok, module_name}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
