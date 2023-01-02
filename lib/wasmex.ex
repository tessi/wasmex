defmodule Wasmex do
  @moduledoc ~S"""
  Wasmex is a fast and secure [WebAssembly](https://webassembly.org/) and [WASI](https://github.com/WebAssembly/WASI) runtime for Elixir.
  It enables lightweight WebAssembly containers to be run in your Elixir backend.
  This is the main module, providing most of the needed API to run WASM binaries.

  It uses [wasmtime](https://wasmtime.dev/) to execute WASM binaries through a NIF.
  [Rust](https://www.rust-lang.org/) is used to implement the NIF to make it as safe as possible.

  Each WASM module must be compiled from a `.wasm` file.
  A compiled WASM module can be instantiated which usually happens in a [GenServer](https://hexdocs.pm/elixir/master/GenServer.html).
  To start the GenServer, `start_link/1` is used:

      iex> bytes = File.read!(TestHelper.wasm_test_file_path())
      iex> {:ok, instance_pid} = Wasmex.start_link(%{bytes: bytes})
      iex> Wasmex.call_function(instance_pid, "sum", [50, -8])
      {:ok, [42]}

  Memory of a WASM instance can be read/written using `Wasmex.Memory`:

      iex> {:ok, pid} = Wasmex.start_link(%{bytes: File.read!(TestHelper.wasm_test_file_path())})
      iex> {:ok, store} = Wasmex.store(pid)
      iex> {:ok, memory} = Wasmex.memory(pid)
      iex> index = 4
      iex> Wasmex.Memory.set_byte(store, memory, index, 42)
      iex> Wasmex.Memory.get_byte(store, memory, index)
      42

  See `start_link/1` for starting and configuring a WASM instance and `call_function/3` for details about calling WASM functions.
  """
  use GenServer

  # Client

  @doc ~S"""
  Starts a GenServer which compiles and instantiates a WASM module from the given `.wasm` or `.wat` bytes.

      iex> bytes = File.read!(TestHelper.wasm_test_file_path())
      iex> {:ok, _pid} = Wasmex.start_link(%{bytes: bytes})

  Alternatively, a precompiled `Wasmex.Module` can be passed with its `Wasmex.Store`:

      iex> {:ok, store} = Wasmex.Store.new()
      iex> {:ok, module} = Wasmex.Module.compile(store, "(module)")
      iex> {:ok, _pid} = Wasmex.start_link(%{store: store, module: module})

  ### Imports

  WASM imports may be given as an additional option.
  Imports are a map of namespace-name to namespaces.
  Each namespace is in turn a map of import-name to import.

      iex> wat = "(module
      ...>          (import \"IO\" \"inspect\" (func $log (param i32)))
      ...>        )"
      iex> io_inspect = fn (%{_memory: %Wasmex.Memory{}, _caller: %Wasmex.StoreOrCaller{}} = _context, i) ->
      ...>                IO.inspect(i)
      ...>              end
      iex> imports = %{
      ...>   IO: %{
      ...>     inspect: {:fn, [:i32], [], io_inspect},
      ...>   }
      ...> }
      iex> {:ok, _pid} = Wasmex.start_link(%{bytes: wat, imports: imports})

  In the example above, we import the `"IO"` namespace.
  That namespace is a map of imports, in this case the `inspect` function, which is represented with a tuple of:

  1. the import type: `:fn` (a function),
  1. the functions parameter types: `[:i32]`,
  1. the functions return types: `[]`, and
  1. the function to be executed: `fn (_context, i) -> IO.inspect(i) end`

  The first param the function receives is always the call context:

      %{
        memory: %Wasmex.Memory{},
        caller: %Wasmex.StoreOrCaller{}
      } = context

  The `caller` MUST be used instead of a `store` in Wasmex API functions.
  Wasmex might deadlock if the `store` is used instead of the `caller`
  (because running the WASM instance holds a Mutex lock on the `store` so
  we cannot use that store again during the execution of an imported function).
  The caller, however, MUST NOT be used outside of the imported functions scope.

  All other params are regular parameters as specified by the parameter type list.

  Valid parameter/return types are:

  - `:i32` a 32 bit integer
  - `:i64` a 64 bit integer
  - `:f32` a 32 bit float
  - `:f64` a 64 bit float

  ### WASI

  Optionally, modules can be run with WebAssembly System Interface (WASI) support.
  WASI functions are provided as native implementations by default but could be overridden
  with Elixir provided functions.

      iex> {:ok, _pid } = Wasmex.start_link(%{bytes: "(module)", wasi: true})

  It is possible to overwrite the default WASI functions using the imports map:

      iex> imports = %{
      ...>   wasi_snapshot_preview1: %{
      ...>     random_get: {:fn, [:i32, :i32], [:i32],
      ...>                  fn %{memory: memory, caller: caller}, address, size ->
      ...>                    Enum.each(0..size, fn index ->
      ...>                      Wasmex.Memory.set_byte(caller, memory, address + index, 0)
      ...>                    end)
      ...>                    # We chose `4` as the random number with a fair dice roll
      ...>                    Wasmex.Memory.set_byte(caller, memory, address, 4)
      ...>                    0
      ...>                  end
      ...>                 }
      ...>   }
      ...> }
      iex> {:ok, _pid} = Wasmex.start_link(%{bytes: "(module)", imports: imports})

  In the example above, we overwrite the `random_get` function which is (as all other WASI functions)
  implemented in Rust. This way our Elixir implementation of `random_get` is used instead of the
  default WASI implementation.

  Oftentimes, WASI programs need additional inputs like environment variables, arguments,
  or file system access.
  These can configured by additional `Wasmex.Wasi.WasiOptions`:

      iex> wasi_options = %Wasmex.Wasi.WasiOptions{
      ...>   args: ["hello", "from elixir"],
      ...>   env: %{
      ...>     "A_NAME_MAPS" => "to a value",
      ...>     "THE_TEST_WASI_FILE" => "prints all environment variables"
      ...>   },
      ...>   preopen: [%Wasmex.Wasi.PreopenOptions{path: "lib", alias: "src"}]
      ...> }
      iex> {:ok, _pid} = Wasmex.start_link(%{bytes: "(module)", wasi: wasi_options})

  It is also possible to capture stdout, stdin, or stderr of a WASI program using pipes:

      iex> {:ok, stdin} = Wasmex.Pipe.create()
      iex> {:ok, stdout} = Wasmex.Pipe.create()
      iex> wasi_options = %Wasmex.Wasi.WasiOptions{
      ...>   args: ["wasmex", "echo"],
      ...>   stdin: stdin,
      ...>   stdout: stdout
      ...> }
      iex> {:ok, pid } = Wasmex.start_link(%{bytes: File.read!(TestHelper.wasi_test_file_path()), wasi: wasi_options})
      iex> Wasmex.Pipe.write(stdin, "Hey! It compiles! Ship it!")
      iex> Wasmex.Pipe.seek(stdin, 0)
      iex> {:ok, _} = Wasmex.call_function(pid, :_start, [])
      iex> Wasmex.Pipe.seek(stdout, 0)
      iex> Wasmex.Pipe.read(stdout)
      "Hey! It compiles! Ship it!\n"

  In the example above, we call a WASI program which echoes a line from stdin
  back to stdout.
  """
  def start_link(%{} = opts) when not is_map_key(opts, :imports),
    do: start_link(Map.merge(opts, %{imports: %{}}))

  def start_link(%{} = opts) when is_map_key(opts, :module) and not is_map_key(opts, :store),
    do: {:error, :must_specify_store_used_to_compile_module}

  def start_link(%{wasi: true} = opts),
    do: start_link(Map.merge(opts, %{wasi: %Wasmex.Wasi.WasiOptions{}}))

  def start_link(%{bytes: bytes} = opts) do
    with {:ok, store} <- build_store(opts),
         {:ok, module} <- Wasmex.Module.compile(store, bytes) do
      opts
      |> Map.delete(:bytes)
      |> Map.put(:module, module)
      |> Map.put(:store, store)
      |> start_link()
    end
  end

  def start_link(%{store: store, module: module, imports: imports}) when is_map(imports) do
    GenServer.start_link(__MODULE__, %{
      store: store,
      module: module,
      imports: stringify_keys(imports)
    })
  end

  defp build_store(opts) do
    if Map.has_key?(opts, :wasi) do
      Wasmex.Store.new_wasi(stringify_keys(opts[:wasi]))
    else
      Wasmex.Store.new()
    end
  end

  @doc ~S"""
  Returns whether a function export with the given `name` exists in the WASM instance.

  ## Examples

      iex> wat = "(module
      ...>          (func $helloWorld (result i32) (i32.const 42))
      ...>          (export \"hello_world\" (func $helloWorld))
      ...>        )"
      iex> {:ok, pid} = Wasmex.start_link(%{bytes: wat})
      iex> Wasmex.function_exists(pid, "hello_world")
      true
      iex> Wasmex.function_exists(pid, "something_else")
      false
  """
  def function_exists(pid, name) do
    GenServer.call(pid, {:exported_function_exists, stringify(name)})
  end

  @doc ~S"""
  Calls a function with the given `name` and `params` on the WASM instance
  and returns its results.

  ## Example

      iex> wat = "(module
      ...>          (func $helloWorld (result i32) (i32.const 42))
      ...>          (export \"hello_world\" (func $helloWorld))
      ...>        )"
      iex> {:ok, pid} = Wasmex.start_link(%{bytes: wat})
      iex> Wasmex.call_function(pid, "hello_world", [])
      {:ok, [42]}

  ## String Handling

  Strings are common candidates for function parameters and return values.
  However, they can not be used directly when calling WASM functions,
  because WASM only knows number data types.
  Since Strings are just "a bunch of bytes", we can write these bytes into memory
  and give our WASM function a pointer to that memory location.

  ### Strings as Function Parameters

  Given we have the following Rust function that returns the first byte of a string input
  compiled to WASM:

  ```rust
  #[no_mangle]
  pub extern "C" fn string_first_byte(bytes: *const u8, length: usize) -> u8 {
      let slice = unsafe { slice::from_raw_parts(bytes, length) };
      match slice.first() {
          Some(&i) => i,
          None => 0,
      }
  }
  ```

  This WASM function can be called from Elixir:

      iex> {:ok, pid} = Wasmex.start_link(%{bytes: File.read!(TestHelper.wasm_test_file_path())})
      iex> {:ok, store} = Wasmex.store(pid)
      iex> {:ok, memory} = Wasmex.memory(pid)
      iex> index = 42
      iex> string = "hello, world"
      iex> Wasmex.Memory.write_binary(store, memory, index, string)
      iex> Wasmex.call_function(pid, "string_first_byte", [index, String.length(string)])
      {:ok, [104]} # 104 is the letter "h" in ASCII/UTF-8 encoding

  Please not that Elixir and Rust assume Strings to be valid UTF-8. Take care when handling other encodings.

  ### Strings as Function Return Values

  Given we have the following Rust function compiled to WASM (again, copied from our test code):

  ```rust
  #[no_mangle]
  pub extern "C" fn string() -> *const u8 {
      b"Hello, World!".as_ptr()
  }
  ```

  This function returns a _pointer_ to its memory.
  This memory location contains the String "Hello, World!".

  This is how we would receive this String in Elixir:

      iex> {:ok, pid} = Wasmex.start_link(%{bytes: File.read!(TestHelper.wasm_test_file_path())})
      iex> {:ok, store} = Wasmex.store(pid)
      iex> {:ok, memory} = Wasmex.memory(pid)
      iex> {:ok, [pointer]} = Wasmex.call_function(pid, "string", [])
      iex> Wasmex.Memory.read_string(store, memory, pointer, 13)
      "Hello, World!"

  ## Specifying a timeout

  The default timeout for `call_function` is 5 seconds, or 5000 milliseconds.
  When calling a long-running function, you can specify a timeout value (in milliseconds) for this call.

      iex> wat = "(module
      ...>          (func $helloWorld (result i32) (i32.const 42))
      ...>          (export \"hello_world\" (func $helloWorld))
      ...>        )"
      iex> {:ok, pid} = Wasmex.start_link(%{bytes: wat})
      iex> Wasmex.call_function(pid, "hello_world", [], 10_000)
      {:ok, [42]}

  In the example above, we specify a timeout of 10 seconds.
  """
  def call_function(pid, name, params, timeout \\ 5000) do
    GenServer.call(pid, {:call_function, stringify(name), params}, timeout)
  end

  @doc ~S"""
  Returns the exported `Wasmex.Memory` of the given WASM instance.

  ## Example

      iex> {:ok, pid} = Wasmex.start_link(%{bytes: File.read!(TestHelper.wasm_test_file_path())})
      iex> {:ok, %Wasmex.Memory{}} = Wasmex.memory(pid)
  """
  def memory(pid), do: GenServer.call(pid, {:memory})

  @doc ~S"""
  Returns the `Wasmex.Store` of the WASM instance.

  ## Example

      iex> {:ok, pid} = Wasmex.start_link(%{bytes: File.read!(TestHelper.wasm_test_file_path())})
      iex> {:ok, %Wasmex.StoreOrCaller{}} = Wasmex.store(pid)
  """
  def store(pid), do: GenServer.call(pid, {:store})

  defp stringify_keys(struct) when is_struct(struct), do: struct

  defp stringify_keys(map) when is_map(map) do
    for {key, val} <- map, into: %{}, do: {stringify(key), stringify_keys(val)}
  end

  defp stringify_keys(value), do: value

  defp stringify(s) when is_binary(s), do: s
  defp stringify(s) when is_atom(s), do: Atom.to_string(s)

  # Server

  @impl true
  def init(%{store: store, module: module, imports: imports} = state) when is_map(imports) do
    case Wasmex.Instance.new(store, module, imports) do
      {:ok, instance} -> {:ok, Map.merge(state, %{instance: instance})}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def handle_call({:memory}, _from, %{store: store, instance: instance} = state) do
    case Wasmex.Memory.from_instance(store, instance) do
      {:ok, memory} -> {:reply, {:ok, memory}, state}
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  @impl true
  def handle_call({:store}, _from, %{store: store} = state) do
    {:reply, {:ok, store}, state}
  end

  @impl true
  def handle_call(
        {:exported_function_exists, name},
        _from,
        %{store: store, instance: instance} = state
      )
      when is_binary(name) do
    {:reply, Wasmex.Instance.function_export_exists(store, instance, name), state}
  end

  @impl true
  def handle_call(
        {:call_function, name, params},
        from,
        %{store: store, instance: instance} = state
      ) do
    :ok = Wasmex.Instance.call_exported_function(store, instance, name, params, from)
    {:noreply, state}
  end

  @impl true
  def handle_info({:returned_function_call, result, from}, state) do
    GenServer.reply(from, result)
    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:invoke_callback, namespace_name, import_name, context, params, token},
        %{imports: imports} = state
      ) do
    context =
      Map.merge(
        context,
        %{
          memory: Wasmex.Memory.__wrap_resource__(Map.get(context, :memory)),
          caller: Wasmex.StoreOrCaller.__wrap_resource__(Map.get(context, :caller))
        }
      )

    {success, return_value} =
      try do
        {:fn, _params, _returns, callback} =
          imports
          |> Map.get(namespace_name, %{})
          |> Map.get(import_name)

        {true, apply(callback, [context | params])}
      rescue
        e in RuntimeError -> {false, e.message}
      end

    return_values =
      case return_value do
        nil -> []
        _ -> [return_value]
      end

    :ok = Wasmex.Native.instance_receive_callback_result(token, success, return_values)
    {:noreply, state}
  end
end
