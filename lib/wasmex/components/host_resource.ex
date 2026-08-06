defmodule Wasmex.Components.HostResource do
  @moduledoc """
  Defines a host-owned WebAssembly component resource implemented in Elixir.

  Given this imported WIT resource:

  ```wit
  interface counters {
    resource counter {
      constructor(initial: u32);
      with-value: static func(value: u32) -> counter;
      increment: func() -> u32;
      take-other: func(other: counter) -> u32;
    }
  }
  ```

  implement its callbacks and pass the generated imports to the component:

  ```elixir
  defmodule CounterHost do
    use Wasmex.Components.HostResource,
      wit_path: "wit",
      resource: "counter"

    def new(initial), do: start_counter(initial)
    def with_value(value), do: start_counter(value)
    def increment(counter), do: Agent.get_and_update(counter, &{&1 + 1, &1 + 1})

    # `other` is an owned argument, so this callback is now responsible for it.
    def take_other(counter, other) do
      value = Agent.get(counter, & &1) + Agent.get(other, & &1)
      Agent.stop(other)
      value
    end

    def drop(counter), do: Agent.stop(counter)

    defp start_counter(initial) do
      {:ok, counter} = Agent.start_link(fn -> initial end)
      counter
    end
  end

  {:ok, component} =
    Wasmex.Components.start_link(
      bytes: File.read!("component.wasm"),
      imports: CounterHost.imports()
    )
  ```

  ## Callback mapping

  A resource is represented by any opaque Elixir term. A PID, reference, ETS
  key, or struct containing those values works well when the resource has
  mutable state.

  * A WIT constructor maps to `new/arity` and returns the opaque term.
  * A method maps to its snake-case name and receives the opaque term first.
  * A static function maps to its snake-case name without a resource argument.
  * A resource returned directly or inside a tuple, option, result, record,
    variant, or list is represented by an opaque term in the matching Elixir
    position.
  * `drop/1` is called when the guest destroys an owned handle. It defaults to
    a no-op and should be overridden when the term owns external state.

  Passing `borrow<T>` to a callback leaves the guest handle live. Passing
  `own<T>` transfers ownership to the callback and removes the guest handle;
  `drop/1` is not subsequently called for that handle. The callback must either
  release the state or return it in a resource-typed result.

  Callback exceptions and incompatible return values trap the active component
  call. The component server itself remains alive. Wasmex releases any
  partially lowered Wasmtime handles, but a callback that allocated external
  state before returning an invalid value remains responsible for that state.

  ## Multiple resources and worlds

  Merge resources imported from the same or different interfaces with:

  ```elixir
  imports =
    Wasmex.Components.HostResource.merge_imports([
      CounterHost,
      LabelHost,
      %{
        "package:namespace/interface@version" => %{
          "freestanding-function" => {:fn, &MyHost.function/1}
        }
      }
    ])
  ```

  Maps can therefore be included for freestanding imports that share an
  interface with a generated resource.

  Set `:world` when the WIT package contains multiple worlds. If multiple
  imported interfaces contain the same resource name, select one with
  `interface: "package:namespace/interface@version"`.

  Use `wit: source` for a self-contained WIT package. Use `wit_path: path` for
  a WIT file or directory. A directory may contain the standard `deps`
  subdirectory, making `wit_path:` the best choice for packages that import
  WASI or other dependency packages. Files used beneath the path are registered
  as external compile resources, so changing them recompiles the host module.

  User imports are linked after Wasmtime's built-in WASI interfaces and may
  intentionally override them. For example, a module selecting
  `interface: "wasi:io/error@0.2.12"` can implement that standard resource in
  Elixir. The component and host WIT versions must match exactly.
  """

  alias Wasmex.Components.HostResource.Discovery

  defmacro __using__(opts) do
    {wit_source, wit_path, external_resources} = wit_input!(opts, __CALLER__)

    {resource_name, _binding} =
      opts |> Keyword.fetch!(:resource) |> Code.eval_quoted([], __CALLER__)

    world =
      case Keyword.fetch(opts, :world) do
        {:ok, quoted} -> quoted |> Code.eval_quoted([], __CALLER__) |> elem(0)
        :error -> nil
      end

    interface =
      case Keyword.fetch(opts, :interface) do
        {:ok, quoted} -> quoted |> Code.eval_quoted([], __CALLER__) |> elem(0)
        :error -> nil
      end

    resource_info =
      resource_info!(wit_source, wit_path, resource_name, world, interface)

    callbacks = callbacks(resource_info)
    imports = imports_ast(resource_info)

    external_resource_attributes =
      Enum.map(external_resources, fn path ->
        quote do
          @external_resource unquote(path)
        end
      end)

    quote do
      unquote_splicing(external_resource_attributes)
      @before_compile Wasmex.Components.HostResource
      @wasmex_host_resource_callbacks unquote(callbacks)

      @doc "Returns the component import map for this host resource."
      def imports do
        unquote(imports)
      end

      @doc "Releases the opaque Elixir state associated with a resource."
      def drop(_resource), do: :ok

      defoverridable drop: 1
    end
  end

  defmacro __before_compile__(env) do
    callbacks = Module.get_attribute(env.module, :wasmex_host_resource_callbacks)

    missing =
      Enum.reject(callbacks, fn callback ->
        Module.defines?(env.module, callback, :def)
      end)

    if missing != [] do
      formatted = Enum.map_join(missing, ", ", fn {name, arity} -> "#{name}/#{arity}" end)

      raise CompileError,
        file: env.file,
        line: env.line,
        description: "Missing host resource callbacks: #{formatted}"
    end
  end

  @doc """
  Deep-merges generated host-resource modules and ordinary import maps.
  """
  @spec merge_imports([module() | map()]) :: map()
  def merge_imports(sources) when is_list(sources) do
    Enum.reduce(sources, %{}, fn source, imports ->
      source_imports = if is_atom(source), do: source.imports(), else: source

      Map.merge(imports, source_imports, fn _interface, left, right ->
        Map.merge(left, right)
      end)
    end)
  end

  defp wit_input!(opts, caller) do
    case {Keyword.fetch(opts, :wit), Keyword.fetch(opts, :wit_path)} do
      {{:ok, wit}, :error} ->
        {wit, _binding} = Code.eval_quoted(wit, [], caller)
        {wit, nil, []}

      {:error, {:ok, wit_path}} ->
        {wit_path, _binding} = Code.eval_quoted(wit_path, [], caller)
        wit_path = validate_wit_path!(wit_path)
        {nil, wit_path, external_resources(wit_path)}

      {{:ok, _wit}, {:ok, _wit_path}} ->
        raise CompileError,
          file: caller.file,
          line: caller.line,
          description: "Pass either :wit or :wit_path, not both"

      {:error, :error} ->
        raise CompileError,
          file: caller.file,
          line: caller.line,
          description: "Missing required :wit or :wit_path option"
    end
  end

  defp validate_wit_path!(wit_path) when is_binary(wit_path), do: Path.expand(wit_path)

  defp validate_wit_path!(wit_path) do
    raise CompileError,
      description: "The :wit_path option must evaluate to a path, got: #{inspect(wit_path)}"
  end

  defp external_resources(wit_path) do
    if File.dir?(wit_path) do
      [wit_path | Path.wildcard(Path.join(wit_path, "**/*"), match_dot: true)]
      |> Enum.filter(&(File.dir?(&1) or File.regular?(&1)))
      |> Enum.sort()
    else
      [wit_path]
    end
  end

  defp resource_info!(wit, nil, resource_name, world, interface) when is_binary(wit) do
    case Discovery.get_resource_from_wit(wit, resource_name,
           world: world,
           interface: interface
         ) do
      {:ok, resource_info} ->
        validate_resource_info!(resource_info)
        resource_info

      {:error, reason} ->
        raise CompileError,
          description:
            "Failed to discover host resource #{inspect(resource_name)}: #{inspect(reason)}"
    end
  end

  defp resource_info!(nil, wit_path, resource_name, world, interface) do
    case Discovery.get_resource_from_path(wit_path, resource_name,
           world: world,
           interface: interface
         ) do
      {:ok, resource_info} ->
        validate_resource_info!(resource_info)
        resource_info

      {:error, reason} ->
        raise CompileError,
          description:
            "Failed to discover host resource #{inspect(resource_name)} from #{inspect(wit_path)}: #{inspect(reason)}"
    end
  end

  defp resource_info!(wit, nil, _resource_name, _world, _interface) do
    raise CompileError,
      description: "The :wit option must evaluate to WIT source text, got: #{inspect(wit)}"
  end

  defp validate_resource_info!(resource_info) do
    has_constructor? = Enum.any?(resource_info.functions, &(&1.kind == :constructor))

    names =
      resource_info.functions
      |> Enum.reject(&(&1.kind == :constructor))
      |> Enum.map(& &1.elixir_name)

    cond do
      (duplicates = names -- Enum.uniq(names)) != [] ->
        raise CompileError,
          description:
            "Host resource `#{resource_info.name}` has colliding Elixir callback names: #{Enum.join(Enum.uniq(duplicates), ", ")}"

      reserved_name = Enum.find(names, &(&1 in ["drop", "imports"])) ->
        raise CompileError,
          description:
            "Host resource function `#{reserved_name}` conflicts with the generated API"

      has_constructor? and "new" in names ->
        raise CompileError,
          description:
            "Host resource function `new` conflicts with the generated constructor callback"

      true ->
        :ok
    end
  end

  defp callbacks(resource_info) do
    Enum.map(resource_info.functions, fn function ->
      {callback_name(function), callback_arity(function)}
    end)
  end

  defp imports_ast(resource_info) do
    interface = hd(resource_info.interface_path)
    resource_name = resource_info.name

    function_entries =
      Enum.map(resource_info.functions, fn function ->
        callback_name = callback_name(function)
        callback_arity = callback_arity(function)

        quote do
          {
            unquote(function.canonical_name),
            {:fn, Function.capture(__MODULE__, unquote(callback_name), unquote(callback_arity))}
          }
        end
      end)

    quote do
      %{
        unquote(interface) =>
          Map.new([
            {
              unquote(resource_name),
              {:resource, Function.capture(__MODULE__, :drop, 1)}
            },
            unquote_splicing(function_entries)
          ])
      }
    end
  end

  defp callback_name(%{kind: :constructor}), do: :new
  defp callback_name(function), do: String.to_atom(function.elixir_name)

  defp callback_arity(%{kind: kind, arity: arity}) when kind in [:method, :async_method],
    do: arity + 1

  defp callback_arity(function), do: function.arity
end
