defmodule Wasmex.Components do
  @moduledoc """
  This is the entry point to support for the [WebAssembly Component Model](https://component-model.bytecodealliance.org/).

  The Component Model is a higher-level way to interact with WebAssembly modules that provides:
  - Better type safety through interface types
  - Standardized way to define imports and exports using WIT (WebAssembly Interface Types)
  - WASI support for system interface capabilities

  ## Basic Usage

  To use a WebAssembly component:

  1. Start a component instance:
  ```elixir
  # Using raw bytes
  bytes = File.read!("path/to/component.wasm")
  {:ok, pid} = Wasmex.Components.start_link(%{bytes: bytes})

  # Using a file path
  {:ok, pid} = Wasmex.Components.start_link(%{path: "path/to/component.wasm"})

  # With WASI support
  {:ok, pid} = Wasmex.Components.start_link(%{
    path: "path/to/component.wasm",
    wasi: %Wasmex.Wasi.WasiP2Options{}
  })

  # With imports (host functions the component can call)
  {:ok, pid} = Wasmex.Components.start_link(%{
    bytes: bytes,
    imports: %{
      "host_function" => {:fn, &MyModule.host_function/1}
    }
  })
  ```

  2. Call exported functions:
  ```elixir
  {:ok, result} = Wasmex.Components.call_function(pid, "exported_function", ["param1"])
  ```

  ## Ahead-of-time compilation

  Use `Wasmex.Engine.precompile_component/2` to compile an artifact that can
  be saved and loaded on a compatible host.

  ```elixir
  build_engine = Wasmex.Engine.default()
  {:ok, artifact} = Wasmex.Engine.precompile_component(build_engine, File.read!("component.wasm"))

  # On the runtime host, load the trusted artifact and use the same Engine for the Store.
  engine = Wasmex.Engine.default()
  {:ok, component} = Wasmex.Components.Component.unsafe_deserialize(artifact, engine)
  {:ok, store} = Wasmex.Components.Store.new(nil, engine)
  {:ok, pid} = Wasmex.Components.start_link(component: component, store: store)
  ```

  ## Component Interface Types

  The component model supports the following WIT (WebAssembly Interface Type) types:

  ### Supported Types

  - **Primitive Types**
    - Integers: `s8`, `s16`, `s32`, `s64`, `u8`, `u16`, `u32`, `u64`
    - Floats: `f32`, `f64`
    - `bool`
    - `string`
    - `char` (maps to Elixir strings with a single character)
      ```wit
      char
      ```
      ```elixir
      "A"  # or from a code point
      937  # Ω
      ```

  - **Compound Types**
    - `record` (maps to Elixir maps with atom keys)
      ```wit
      record point { x: u32, y: u32 }
      ```
      ```elixir
      %{x: 1, y: 2}
      ```

    - `list<T>` (maps to Elixir lists)
      ```wit
      list<u32>
      ```
      ```elixir
      [1, 2, 3]
      ```
      For `list<u8>`, Elixir callers can also pass binaries such as `<<0, 128, 255>>`.
      Host callbacks can return binaries for `list<u8>` results. Set
      `binary_byte_lists: true` when starting the component to receive `list<u8>`
      values as binaries, including nested values and empty lists (`<<>>`). This
      applies to Wasm results and arguments sent to host callbacks. The default
      is to receive byte lists.

    - `tuple<T1, T2>` (maps to Elixir tuples)
      ```wit
      tuple<u32, string>
      ```
      ```elixir
      {1, "two"}
      ```

    - `option<T>` (maps to `:none` or `{:some, value}`)
      ```wit
      option<u32>
      ```
      ```elixir
      :none  # or
      {:some, 42}
      ```

    - `enum` (maps to Elixir atoms)
      ```wit
      enum size { s, m, l }
      ```
      ```elixir
      :s  # or :m or :l
      ```

    - `variant` (tagged unions, maps to atoms or tuples)
      ```wit
      variant filter { all, none, lt(u32) }
      ```
      ```elixir
      :all     # variant without payload
      :none    # variant without payload
      {:lt, 7} # variant with payload
      ```

    - `flags` (maps to Elixir maps with boolean values)
      ```wit
      flags permission { read, write, exec }
      ```
      ```elixir
      %{read: true, write: true, exec: false}
      # Note: When returned from WebAssembly, only the flags set to true are included
      # %{read: true, exec: true}
      ```

    - `result<T, E>` (maps to Elixir tuples with :ok/:error)
      ```wit
      result<u32, u32>
      ```
      ```elixir
      {:ok, 42}      # success case
      {:error, 404}  # error case
      ```

  ### Guest Resources

  Guest-owned resources exported by a component can be constructed and called
  with `Wasmex.Components.GuestResource`. It can generate an arity-aware API
  from WIT:

  ```elixir
  defmodule Counter do
    use Wasmex.Components.GuestResource,
      wit: File.read!("counter.wit"),
      resource: "counter"
  end

  {:ok, counter} = Counter.new(component_pid, 42)
  {:ok, value} = Counter.get_value(counter)
  :ok = Counter.drop(counter)
  ```

  ### Host Resources

  Host-owned resources imported by a component can be implemented with
  `Wasmex.Components.HostResource`:

  ```elixir
  defmodule CounterHost do
    use Wasmex.Components.HostResource,
      wit_path: "wit",
      resource: "counter"

    def new(initial), do: MyCounter.start(initial)
    def get_value(counter), do: MyCounter.value(counter)
    def drop(counter), do: MyCounter.stop(counter)
  end

  {:ok, component_pid} =
    Wasmex.Components.start_link(
      bytes: component,
      imports: CounterHost.imports()
    )
  ```

  Constructors return an opaque Elixir term representing the resource. Methods
  and the destructor receive that term. Borrowed handles remain live, while
  owned handles transfer ownership to the receiving callback. `wit_path:`
  resolves dependency packages from a standard `wit/deps` directory.

  Guest-owned resource values passed through arbitrary freestanding component
  functions are not yet supported.

  Support for the Component Model should be considered beta quality.

  ## Options

  The `start_link/1` function accepts the following options:

  * `:bytes` - Raw WebAssembly component bytes (mutually exclusive with `:path`)
  * `:path` - Path to a WebAssembly component file (mutually exclusive with `:bytes`)
  * `:component` - Compiled `Wasmex.Components.Component`. Supply it with
    `:store` in place of `:bytes` or `:path`.
  * `:store` - Optional `Wasmex.Components.Store`. For a compiled component,
    use a Store created with the Engine that compiled or loaded the component.
  * `:wasi` - Optional WASI configuration as `Wasmex.Wasi.WasiP2Options` struct for system interface capabilities
  * `:binary_byte_lists` - Receive WIT `list<u8>` values as binaries. Defaults to `false`.
  * `:imports` - Optional map of host functions that can be called by the WebAssembly component
    * Keys are function names as strings
    * Values are tuples of `{:fn, function}` where function is the host function to call
    * Modules generated with `Wasmex.Components.HostResource` expose
      `imports/0` definitions for host-owned resources

  Additionally, any standard GenServer options (like `:name`) are supported.

  ### Examples

  ```elixir
  # With raw bytes
  {:ok, pid} = Wasmex.Components.start_link(%{
    bytes: File.read!("component.wasm"),
    name: MyComponent
  })

  # With WASI configuration
  {:ok, pid} = Wasmex.Components.start_link(%{
    path: "component.wasm",
    wasi: %Wasmex.Wasi.WasiP2Options{
      allow_http: true
    }
  })

  # With host functions
  {:ok, pid} = Wasmex.Components.start_link(%{
    path: "component.wasm",
    imports: %{
      "log" => {:fn, &IO.puts/1},
      "add" => {:fn, fn(a, b) -> a + b end}
    }
  })
  ```
  """

  use GenServer

  alias Wasmex.Components.Component

  @doc """
  Starts a new WebAssembly component instance.

  ## Options

    * `:bytes` - Raw WebAssembly component bytes (mutually exclusive with `:path`)
    * `:path` - Path to a WebAssembly component file (mutually exclusive with `:bytes`)
    * `:component` - Compiled `Wasmex.Components.Component`. Supply it with
      `:store` in place of `:bytes` or `:path`.
    * `:store` - Optional `Wasmex.Components.Store`. When supplying a compiled
      component, create its Store with the same Engine and configure WASI and
      Store limits when constructing the Store.
    * `:wasi` - Optional WASI configuration as `Wasmex.Wasi.WasiP2Options` struct
    * `:binary_byte_lists` - Receive WIT `list<u8>` values as binaries. Defaults to `false`.
    * `:imports` - Optional map of host functions that can be called by the component
    * Any standard GenServer options (like `:name`)

  ## Returns

    * `{:ok, pid}` on success
    * `{:error, reason}` on failure
  """
  def start_link(opts) when is_list(opts) or is_map(opts) do
    opts = normalize_opts(opts)
    binary_byte_lists = Keyword.get(opts, :binary_byte_lists, false)

    with true <- is_boolean(binary_byte_lists) || {:error, :invalid_binary_byte_lists},
         {:ok, store} <- get_store(opts),
         {:ok, component} <- get_component(opts, store) do
      imports = Keyword.get(opts, :imports, %{})

      GenServer.start_link(
        __MODULE__,
        %{
          store: store,
          component: component,
          imports: imports,
          binary_byte_lists: binary_byte_lists
        },
        opts
      )
    end
  end

  defp normalize_opts(opts) when is_map(opts) do
    opts
    |> Map.to_list()
    |> Keyword.new()
  end

  defp normalize_opts(opts) when is_list(opts), do: opts

  defp get_component(opts, store) do
    case Keyword.fetch(opts, :component) do
      :error ->
        Component.new(store, get_component_bytes(opts))

      {:ok, %Component{} = component} ->
        if Keyword.has_key?(opts, :bytes) or Keyword.has_key?(opts, :path) do
          {:error, :conflicting_component_sources}
        else
          {:ok, component}
        end

      {:ok, _invalid_component} ->
        {:error, :invalid_component}
    end
  end

  defp get_component_bytes(opts) do
    cond do
      bytes = Keyword.get(opts, :bytes) -> bytes
      path = Keyword.get(opts, :path) -> File.read!(path)
      true -> raise ArgumentError, "Either :bytes or :path must be provided"
    end
  end

  defp get_store(opts) do
    case {Keyword.get(opts, :store), Keyword.has_key?(opts, :component)} do
      {nil, true} -> {:error, :must_specify_store_for_component}
      {nil, false} -> build_store(opts)
      {store, _} -> {:ok, store}
    end
  end

  defp build_store(opts) do
    store_limits = Keyword.get(opts, :store_limits, %Wasmex.StoreLimits{})

    if wasi_options = Keyword.get(opts, :wasi) do
      Wasmex.Components.Store.new_wasi(wasi_options, store_limits)
    else
      Wasmex.Components.Store.new(store_limits)
    end
  end

  @type function_name_or_path :: String.t() | atom() | [String.t() | atom()] | tuple()

  @doc """
  Calls an exported component function.

  `name_or_path` may be a function name or a path identifying an exported
  interface function. Parameters and results use the Elixir representations
  described in the component interface type documentation above.

  The default timeout is 5 seconds. A timeout exits the calling process unless
  it catches the exit, just like `GenServer.call/3`. The deadline includes
  time waiting in both the server and Store queues. A call that expires before
  guest execution leaves the instance usable. Use `:infinity` to run without a
  deadline.

  If the deadline expires while the guest call is in progress, Wasmex requests
  interruption at the next Wasmtime epoch. Later calls through this API return
  `{:error, :instance_interrupted}`, even if the guest finished after the
  deadline. Stop the component server and start a fresh instance to continue
  using the component.

  An Elixir callback or WASI host operation already in progress may continue
  after the deadline. Later operations on the same Store wait for it to finish.
  """
  @spec call_function(GenServer.server(), function_name_or_path(), list(any()), timeout()) ::
          {:ok, any()} | {:error, any()}
  def call_function(pid, name_or_path, params, timeout \\ 5000) do
    deadline =
      case timeout do
        :infinity ->
          nil

        timeout when is_integer(timeout) and timeout >= 0 ->
          {System.monotonic_time(:millisecond) + timeout, timeout}
      end

    GenServer.call(pid, {:call_function, name_or_path, params, deadline}, timeout)
  end

  @doc """
  Returns the low-level component instance owned by a component server.

  Guest resource APIs accept either this value or the component server directly.
  """
  @spec instance(GenServer.server()) :: Wasmex.Components.Instance.t()
  def instance(pid), do: GenServer.call(pid, :instance)

  @impl true
  def init(%{store: store, component: component, imports: imports} = state) do
    binary_byte_lists = Map.get(state, :binary_byte_lists, false)

    case Wasmex.Components.Instance.new(store, component, imports, binary_byte_lists) do
      {:ok, instance} ->
        {:ok, Map.merge(state, %{instance: instance, component: component, imports: imports})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def handle_call(
        {:call_function, name, params, deadline},
        {caller, _tag} = from,
        %{instance: instance} = state
      ) do
    timeout =
      case deadline do
        {deadline, _timeout} when node(caller) == node() ->
          max(deadline - System.monotonic_time(:millisecond), 0)

        {_deadline, timeout} ->
          # Monotonic timestamps cannot be compared across nodes.
          timeout

        timeout ->
          timeout
      end

    if timeout != 0 do
      :ok = Wasmex.Components.Instance.call_function(instance, name, params, from, timeout)
    end

    {:noreply, state}
  end

  def handle_call(:instance, _from, %{instance: instance} = state) do
    {:reply, instance, state}
  end

  @impl true
  def handle_info(
        {:invoke_callback, namespace, name, token, params},
        %{imports: imports, instance: _instance} = state
      ) do
    {_kind, function} =
      if namespace do
        imports
        |> Map.get(namespace)
        |> Map.get(name)
      else
        Map.get(imports, name)
      end

    {success, result} =
      try do
        {true, apply(function, params)}
      rescue
        exception -> {false, Exception.message(exception)}
      catch
        kind, reason -> {false, Exception.format_banner(kind, reason)}
      end

    :ok =
      Wasmex.Native.component_receive_callback_result(
        token,
        success,
        result
      )

    {:noreply, state}
  end
end
