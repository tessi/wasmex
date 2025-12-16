defmodule Wasmex.Components.GuestResource do
  @moduledoc """
  Macro for generating elixir modules for guest resources.

  This macro parses WebAssembly Interface Type (WIT) definitions and generates
  a GenServer implementation for interacting with WASM guest resources.

  ## Example

      defmodule MyApp.Counter do
        @wit \"""
        package component:counter;

          interface types {
              resource counter {
                  constructor(initial: u32);
                  increment: func() -> u32;
                  get-value: func() -> u32;
                  reset: func(value: u32);
              }

              make-counter: func(initial: u32) -> counter;
              use-counter: func(c: borrow<counter>) -> u32;
          }

          world example {
              export types;
          }
        \"""

        use Wasmex.Components.GuestResource,
          wit: @wit
          resource: "counter"
      end

  This generates:
  - `MyApp.Counter.start_link/2`
  - `MyApp.Counter.increment/1`
  - `MyApp.Counter.get_value/1`
  - `MyApp.Counter.reset/2`
  """

  defmacro __using__(opts) do
    {wit, _} = Code.eval_quoted(Keyword.fetch!(opts, :wit))
    {resource_name, _} = Code.eval_quoted(Keyword.fetch!(opts, :resource))
    resource_info = parse_wit_at_compile_time(wit, resource_name)

    quote do
      use GenServer
      require Logger

      # Internal state structure
      defmodule State do
        @moduledoc false
        defstruct [:instance, :resource_handle, :resource_name, :interface_path]
      end

      unquote_splicing(generate_public_api(resource_info))
      unquote_splicing(generate_genserver_callbacks(resource_info))
      unquote_splicing(generate_private_helpers())
    end
  end

  defp parse_wit_at_compile_time(wit, resource_name) do
    case Wasmex.Components.GuestResource.Discovery.get_resource_from_wit(wit, resource_name) do
      {:ok, resource_info} ->
        # Generate paths for the resource
        paths = generate_paths(resource_info)
        Map.merge(resource_info, paths)

      {:error, reason} ->
        raise CompileError,
          description: "Failed to parse WIT or find resource: #{inspect(reason)}"
    end
  end

  defp generate_public_api(resource_info) do
    [
      define_start_link(),
      define_child_spec(),
      define_functions(resource_info)
    ]
  end

  defp define_start_link() do
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

  defp define_child_spec() do
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

  defp define_functions(resource_info) do
    resource_info.functions
    |> Enum.reject(&(&1.wit_name == :constructor))
    |> Enum.map(&define_function(&1))
  end

  defp define_function(%{
         wit_name: wit_name,
         elixir_name: elixir_name,
         arity: arity,
         has_return: has_return
       }) do
    cond do
      arity == 1 ->
        quote do
          @doc """
          Calls the `#{unquote(elixir_name)}` function on the resource.

          ## Parameters
            * `resource` - The resource process or name

          ## Returns
            * #{unquote(return_doc(has_return))}
          """
          def unquote(elixir_name)(resource) do
            GenServer.call(resource, {:call_function, unquote(Atom.to_string(wit_name)), []})
          end

          @doc false
          def unquote(elixir_name)(resource, timeout: timeout) when is_integer(timeout) do
            GenServer.call(
              resource,
              {:call_function, unquote(Atom.to_string(wit_name)), []},
              timeout
            )
          end
        end

      arity == 2 ->
        quote do
          @doc """
          Calls the `#{unquote(elixir_name)}` function on the resource.

          ## Parameters
            * `resource` - The resource process or name
            * `arg` - The function argument
          ## Returns
            * #{unquote(return_doc(has_return))}
          """
          def unquote(elixir_name)(resource, arg) do
            GenServer.call(resource, {:call_function, unquote(Atom.to_string(wit_name)), [arg]})
          end

          @doc false
          def unquote(elixir_name)(resource, arg, timeout) when is_integer(timeout) do
            GenServer.call(
              resource,
              {:call_function, unquote(Atom.to_string(wit_name)), [arg]},
              timeout
            )
          end
        end

      true ->
        # skipping param 0 (the implicit self param)
        params = Enum.map(1..(arity - 1), &{:"arg#{&1}", [], nil})

        quote do
          @doc """
          Calls the `#{unquote(elixir_name)}` function on the resource.

          ## Parameters
            * `resource` - The resource process or name
            * `args` - List of function arguments
          ## Returns
            * #{unquote(return_doc(has_return))}
          """
          def unquote(elixir_name)(resource, unquote_splicing(params)) do
            GenServer.call(
              resource,
              {:call_function, unquote(Atom.to_string(wit_name)), [unquote_splicing(params)]}
            )
          end

          @doc false
          def unquote(elixir_name)(resource, unquote_splicing(params), timeout)
              when is_integer(timeout) do
            GenServer.call(
              resource,
              {:call_function, unquote(Atom.to_string(wit_name)), [unquote_splicing(params)]},
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
                resource_name: unquote(resource_info.name),
                interface_path: interface_path
              }

              {:ok, state}

            {:error, reason} ->
              {:stop, {:resource_creation_failed, reason}}
          end
        end

        @impl GenServer
        def handle_call({:call_function, elixir_name, args}, _from, state) do
          wit_name = Wasmex.Components.FieldConverter.identifier_elixir_to_wit(elixir_name)

          try do
            result =
              Wasmex.Components.Instance.call(
                state.instance,
                state.resource_handle,
                wit_name,
                args,
                interface: state.interface_path
              )

            {:reply, result, state}
          rescue
            error ->
              Logger.error("Error calling function #{wit_name}: #{inspect(error)}")
              {:reply, {:error, {:function_call_failed, error}}, state}
          catch
            :exit, reason ->
              Logger.error("Instance died during function call: #{inspect(reason)}")
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
      end
    ]
  end

  defp return_doc(true), do: "`{:ok, result}` on success, `{:error, reason}` on failure"
  defp return_doc(false), do: "`:ok` on success, `{:error, reason}` on failure"

  # Generates constructor and function call paths for a resource.
  #
  ## Example
  # {:ok, resources} = Discovery.get_resource_from_wit("...")
  # resource = List.first(resources)
  # paths = Discovery.generate_paths(resource)
  # # => %{
  # #      constructor_path: ["component:counter/types", "counter"],
  # #      interface_path: ["component:counter/types"]
  # #    }
  defp generate_paths(resource_info, opts \\ []) do
    package = Keyword.get(opts, :package, "component")

    interface_str = to_string(resource_info.interface)
    resource_str = to_string(resource_info.name)

    # Generate standard component model paths
    interface_path = ["#{package}:#{resource_str}/#{interface_str}"]
    constructor_path = interface_path ++ [resource_str]

    %{
      constructor_path: constructor_path,
      interface_path: interface_path
    }
  end

  @doc """
  Creates a module at runtime from WebAssembly Interface Type (WIT) definitions.

  This allows dynamic generation of resource clients without compile-time macros.

  ## Parameters
    * `module_name` - The name for the generated module
    * `wit` - Contents of the WIT file
    * `resource_name` - Name of the resource

  ## Returns
    * `{:ok, module}`
    * `{:error, reason}`
  """
  def create_module(module_name, wit, resource_name) do
    case Wasmex.Components.GuestResource.Discovery.get_resource_from_wit(wit, resource_name) do
      {:ok, resource_info} ->
        paths = generate_paths(resource_info)
        resource_info = Map.merge(resource_info, paths)

        # Generate module code
        module_ast =
          quote do
            use GenServer
            require Logger

            defmodule State do
              @moduledoc false
              defstruct [:instance, :resource_handle, :resource_name, :interface_path]
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
