defmodule Wasmex.Components.GuestResource do
  @moduledoc """
  Guest-owned WebAssembly component resources.

  A resource is a handle tied to the Store and component instance that created
  it. Calls are serialized by that Store, so the handle can be shared between
  processes without an additional owner process.

  For an arity-aware API, generate a module from WIT:

      defmodule Counter do
        use Wasmex.Components.GuestResource,
          wit: File.read!("counter.wit"),
          resource: "counter"
      end

      {:ok, counter} = Counter.new(instance, 42)
      {:ok, 43} = Counter.increment(counter)
      :ok = Counter.drop(counter)

  Generated functions accept a final keyword list with a `:timeout` option.
  Constructors and static functions accept either a `Wasmex.Components` server
  or a low-level `Wasmex.Components.Instance`; methods accept a resource handle.
  Set the macro's `:world` option when the WIT defines multiple worlds.

  Resource handles that are not explicitly dropped have a best-effort native
  finalizer. Passing a handle to an `own<T>` parameter moves it; later calls
  with that handle return an error.

  A timeout interrupts Wasmtime execution and can invalidate that component
  instance. Discard the instance after any timed-out constructor, call, or drop.
  """

  alias Wasmex.Components.GuestResource.Discovery
  alias Wasmex.Components.Instance

  @enforce_keys [:resource]
  defstruct [:resource, :reference]

  @type function_kind :: :method | :async_method
  @type static_function_kind :: :static | :async_static
  @type t :: %__MODULE__{resource: binary(), reference: reference()}

  @doc false
  def __wrap_resource__(resource) do
    %__MODULE__{resource: resource, reference: make_ref()}
  end

  @doc """
  Calls an exported guest resource constructor.

  The resource path consists of the exported interface path followed by the WIT
  resource name.
  """
  @spec new(
          Instance.t() | GenServer.server(),
          Wasmex.Components.function_name_or_path(),
          list(),
          timeout()
        ) ::
          {:ok, t()} | {:error, any()}
  def new(instance_or_server, resource_path, params \\ [], timeout \\ 5000)

  def new(%Instance{} = instance, resource_path, params, timeout)
      when is_list(params) do
    path = normalize_path!(resource_path)

    with :ok <- validate_path(path),
         {:ok, resource} <-
           request(timeout, fn from ->
             Wasmex.Native.component_guest_resource_new(
               instance.store_resource,
               instance.instance_resource,
               path,
               params,
               from,
               Wasmex.Utils.native_timeout(timeout)
             )
           end) do
      {:ok, __wrap_resource__(resource)}
    end
  end

  def new(server, resource_path, params, timeout) when is_list(params) do
    server
    |> Wasmex.Components.instance()
    |> new(resource_path, params, timeout)
  end

  @doc """
  Calls a guest resource method.
  """
  @spec call(t(), function_kind(), String.t() | atom(), list(), timeout()) ::
          :ok | {:ok, any()} | {:error, any()}
  def call(%__MODULE__{} = resource, kind, function_name, params \\ [], timeout \\ 5000)
      when kind in [:method, :async_method] and is_list(params) do
    request(timeout, fn from ->
      Wasmex.Native.component_guest_resource_call(
        resource.resource,
        native_kind(kind),
        identifier_elixir_to_wit(function_name),
        params,
        from,
        Wasmex.Utils.native_timeout(timeout)
      )
    end)
  end

  @doc """
  Calls a static function associated with a guest resource type.

  Static functions take a component instance rather than a resource handle and
  remain callable when no live handle exists.
  """
  @spec call_static(
          Instance.t() | GenServer.server(),
          Wasmex.Components.function_name_or_path(),
          static_function_kind(),
          String.t() | atom(),
          list(),
          timeout()
        ) :: :ok | {:ok, any()} | {:error, any()}
  def call_static(
        instance_or_server,
        resource_path,
        kind,
        function_name,
        params \\ [],
        timeout \\ 5000
      )

  def call_static(
        %Instance{} = instance,
        resource_path,
        kind,
        function_name,
        params,
        timeout
      )
      when kind in [:static, :async_static] and is_list(params) do
    path = normalize_path!(resource_path)

    with :ok <- validate_path(path) do
      request(timeout, fn from ->
        Wasmex.Native.component_guest_resource_call_static(
          instance.store_resource,
          instance.instance_resource,
          path,
          native_kind(kind),
          identifier_elixir_to_wit(function_name),
          params,
          from,
          Wasmex.Utils.native_timeout(timeout)
        )
      end)
    end
  end

  def call_static(server, resource_path, kind, function_name, params, timeout)
      when kind in [:static, :async_static] and is_list(params) do
    server
    |> Wasmex.Components.instance()
    |> call_static(resource_path, kind, function_name, params, timeout)
  end

  @doc """
  Explicitly releases a guest resource.

  Dropping an already-dropped handle succeeds. Methods called afterwards return
  an error.
  """
  @spec drop(t(), timeout()) :: :ok | {:error, any()}
  def drop(%__MODULE__{resource: resource}, timeout \\ 5000) do
    request(timeout, fn from ->
      Wasmex.Native.component_guest_resource_drop(
        resource,
        from,
        Wasmex.Utils.native_timeout(timeout)
      )
    end)
  end

  defmacro __using__(opts) do
    {wit, _binding} = opts |> Keyword.fetch!(:wit) |> Code.eval_quoted([], __CALLER__)

    {resource_name, _binding} =
      opts |> Keyword.fetch!(:resource) |> Code.eval_quoted([], __CALLER__)

    world =
      case Keyword.fetch(opts, :world) do
        {:ok, quoted} -> quoted |> Code.eval_quoted([], __CALLER__) |> elem(0)
        :error -> nil
      end

    wit
    |> resource_info!(resource_name, world)
    |> module_ast()
  end

  defp resource_info!(wit, resource_name, world) when is_binary(wit) do
    case Discovery.get_resource_from_wit(wit, resource_name, world: world) do
      {:ok, resource_info} ->
        case validate_resource_info(resource_info) do
          :ok -> resource_info
          {:error, reason} -> raise CompileError, description: reason
        end

      {:error, reason} ->
        raise CompileError,
          description:
            "Failed to discover guest resource #{inspect(resource_name)}: #{inspect(reason)}"
    end
  end

  defp resource_info!(wit, _resource_name, _world) do
    raise CompileError,
      description: "The :wit option must evaluate to WIT source text, got: #{inspect(wit)}"
  end

  defp validate_resource_info(resource_info) do
    functions = Enum.reject(resource_info.functions, &(&1.kind == :constructor))
    names = Enum.map(functions, & &1.elixir_name)
    reserved = ~w(drop new)

    cond do
      (duplicates = names -- Enum.uniq(names)) != [] ->
        {:error,
         "Guest resource `#{resource_info.name}` has colliding Elixir function names: #{Enum.join(Enum.uniq(duplicates), ", ")}"}

      reserved_name = Enum.find(names, &(&1 in reserved)) ->
        {:error, "Guest resource function `#{reserved_name}` conflicts with the generated API"}

      true ->
        :ok
    end
  end

  defp module_ast(resource_info) do
    constructor =
      resource_info.functions
      |> Enum.find(&(&1.kind == :constructor))
      |> constructor_ast(resource_info.constructor_path)

    functions =
      resource_info.functions
      |> Enum.reject(&(&1.kind == :constructor))
      |> Enum.map(&function_ast(&1, resource_info.constructor_path))

    quote do
      alias Wasmex.Components.GuestResource, as: WasmexGuestResource

      unquote(constructor)
      unquote_splicing(functions)

      @doc "Drops a resource handle."
      def drop(resource, opts \\ []) when is_list(opts) do
        WasmexGuestResource.drop(resource, Keyword.get(opts, :timeout, 5000))
      end
    end
  end

  defp constructor_ast(nil, _path), do: nil

  defp constructor_ast(function, path) do
    args = Macro.generate_arguments(function.arity, __MODULE__)

    quote do
      @doc "Constructs a new guest resource."
      def new(instance, unquote_splicing(args), opts \\ []) when is_list(opts) do
        WasmexGuestResource.new(
          instance,
          unquote(path),
          [unquote_splicing(args)],
          Keyword.get(opts, :timeout, 5000)
        )
      end
    end
  end

  defp function_ast(function, path) do
    function_name = String.to_atom(function.elixir_name)
    args = Macro.generate_arguments(function.arity, __MODULE__)

    case function.kind do
      kind when kind in [:method, :async_method] ->
        quote do
          @doc "Calls the `#{unquote(function.wit_name)}` guest resource method."
          def unquote(function_name)(resource, unquote_splicing(args), opts \\ [])
              when is_list(opts) do
            WasmexGuestResource.call(
              resource,
              unquote(kind),
              unquote(function.wit_name),
              [unquote_splicing(args)],
              Keyword.get(opts, :timeout, 5000)
            )
          end
        end

      kind when kind in [:static, :async_static] ->
        quote do
          @doc "Calls the `#{unquote(function.wit_name)}` guest resource static function."
          def unquote(function_name)(instance, unquote_splicing(args), opts \\ [])
              when is_list(opts) do
            WasmexGuestResource.call_static(
              instance,
              unquote(path),
              unquote(kind),
              unquote(function.wit_name),
              [unquote_splicing(args)],
              Keyword.get(opts, :timeout, 5000)
            )
          end
        end
    end
  end

  defp normalize_path!(path) when is_binary(path) or is_atom(path), do: [to_string(path)]

  defp normalize_path!(path) when is_tuple(path) do
    path
    |> Tuple.to_list()
    |> normalize_path!()
  end

  defp normalize_path!(path) when is_list(path) do
    Enum.map(path, fn
      segment when is_binary(segment) or is_atom(segment) -> to_string(segment)
      segment -> raise ArgumentError, "invalid guest resource path segment: #{inspect(segment)}"
    end)
  end

  defp normalize_path!(path) do
    raise ArgumentError, "invalid guest resource path: #{inspect(path)}"
  end

  defp validate_path(path) when length(path) >= 2, do: :ok

  defp validate_path(_path),
    do: {:error, "Guest resource path must contain an exported interface and a resource name"}

  defp request(timeout, request) do
    reference = make_ref()
    :ok = request.({self(), reference})

    case timeout do
      :infinity ->
        receive do
          {^reference, result} -> result
        end

      timeout when is_integer(timeout) and timeout >= 0 ->
        receive do
          {^reference, result} -> result
        after
          timeout -> {:error, :timeout}
        end
    end
  end

  defp native_kind(:method), do: "method"
  defp native_kind(:async_method), do: "async-method"
  defp native_kind(:static), do: "static"
  defp native_kind(:async_static), do: "async-static"

  defp identifier_elixir_to_wit(identifier) when is_atom(identifier) do
    identifier
    |> Atom.to_string()
    |> identifier_elixir_to_wit()
  end

  defp identifier_elixir_to_wit(identifier) when is_binary(identifier) do
    String.replace(identifier, "_", "-")
  end
end
