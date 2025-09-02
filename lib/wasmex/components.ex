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

    - `tuple<T1, T2>` (maps to Elixir tuples)
      ```wit
      tuple<u32, string>
      ```
      ```elixir
      {1, "two"}
      ```

    - `option<T>` (maps to `nil` or the value)
      ```wit
      option<u32>
      ```
      ```elixir
      nil  # or
      42
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

  ### Currently Unsupported Types

  The following WIT type is not yet supported:
  - Resources

  Support for the Component Model should be considered beta quality.

  ## Options

  The `start_link/1` function accepts the following options:

  * `:bytes` - Raw WebAssembly component bytes (mutually exclusive with `:path`)
  * `:path` - Path to a WebAssembly component file (mutually exclusive with `:bytes`)
  * `:wasi` - Optional WASI configuration as `Wasmex.Wasi.WasiP2Options` struct for system interface capabilities
  * `:imports` - Optional map of host functions that can be called by the WebAssembly component
    * Keys are function names as strings
    * Values are tuples of `{:fn, function}` where function is the host function to call

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

  @doc """
  Starts a new WebAssembly component instance.

  ## Options

    * `:bytes` - Raw WebAssembly component bytes (mutually exclusive with `:path`)
    * `:path` - Path to a WebAssembly component file (mutually exclusive with `:bytes`)
    * `:wasi` - Optional WASI configuration as `Wasmex.Wasi.WasiP2Options` struct
    * `:imports` - Optional map of host functions that can be called by the component
    * Any standard GenServer options (like `:name`)

  ## Returns

    * `{:ok, pid}` on success
    * `{:error, reason}` on failure
  """
  def start_link(opts) when is_list(opts) or is_map(opts) do
    opts = normalize_opts(opts)

    with {:ok, store} <- get_store(opts),
         component_bytes <- get_component_bytes(opts),
         imports <- Keyword.get(opts, :imports, %{}),
         {:ok, component} <- Wasmex.Components.Component.new(store, component_bytes) do
      GenServer.start_link(
        __MODULE__,
        %{store: store, component: component, imports: imports},
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

  defp get_component_bytes(opts) do
    cond do
      bytes = Keyword.get(opts, :bytes) -> bytes
      path = Keyword.get(opts, :path) -> File.read!(path)
      true -> raise ArgumentError, "Either :bytes or :path must be provided"
    end
  end

  defp get_store(opts) do
    case Keyword.get(opts, :store) do
      nil -> build_store(opts)
      store -> {:ok, store}
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

  @type function_name_or_path :: String.t() | list(String.t()) | tuple() | atom() | list(atom())

  @spec call_function(pid(), function_name_or_path(), list(number()), pos_integer()) ::
          {:ok, list(number())} | {:error, any()}
  def call_function(pid, name_or_path, params, timeout \\ 5000) do
    GenServer.call(pid, {:call_function, name_or_path, params}, timeout)
  end

  @impl true
  def init(%{store: store, component: component, imports: imports} = state) do
    case Wasmex.Components.Instance.new(store, component, imports) do
      {:ok, instance} ->
        {:ok, Map.merge(state, %{instance: instance, component: component, imports: imports})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def handle_call(
        {:call_function, name, params},
        from,
        %{instance: instance} = state
      ) do
    :ok = Wasmex.Components.Instance.call_function(instance, name, params, from)
    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:invoke_callback, namespace, name, token, params},
        %{imports: imports, instance: _instance, component: component} = state
      ) do
    {:fn, function} =
      if namespace do
        imports
        |> Map.get(namespace)
        |> Map.get(name)
      else
        Map.get(imports, name)
      end

    result = apply(function, params)
    :ok = Wasmex.Native.component_receive_callback_result(component.resource, token, true, result)
    {:noreply, state}
  end
end
