defmodule Wasmex.Instance do
  @moduledoc ~S"""
  Instantiates a Wasm module and allows calling exported functions on it.

  In the majority of cases, you will not need to use this module directly
  but use the main module `Wasmex` instead.
  This module expects to be executed within GenServer context which `Wasmex` sets up.
  """

  @type t :: %__MODULE__{
          resource: binary(),
          reference: reference()
        }

  defstruct resource: nil,
            # The actual NIF instance resource.
            # Normally the compiler will happily do stuff like inlining the
            # resource in attributes. This will convert the resource into an
            # empty binary with no warning. This will make that harder to
            # accidentally do.
            reference: nil

  defp __wrap_resource__(resource) do
    %__MODULE__{
      resource: resource,
      reference: make_ref()
    }
  end

  @doc ~S"""
  Instantiates a Wasm module with the given imports.

  Returns the instantiated Wasm instance.

  The `import` parameter is a nested map of Wasm namespaces.
  Each namespace consists of a name and a map of function names to function signatures.

  The `links` parameter is a list of name-module pairs that are dynamically linked to the instance.

  Function signatures are a tuple of the form `{:fn, arg_types, return_types, callback}`.
  Where `arg_types` and `return_types` are lists of `:i32`, `:i64`, `:f32`, `:f64`, `:v128`.

  Each `callback` function receives a `context` map as the first argument followed by the arguments specified in its signature.
  `context` has the following keys:

    * `:memory` - The default exported `Wasmex.Memory` of the Wasm instance
    * `:caller` - The caller of the Wasm instance which MUST be used instead of a `Wasmex.Store` in all Wasmex functions called from within the callback. Failure to do so will result in a deadlock. The `caller` MUST NOT be used outside of the callback.

  ## Example

  This example instantiates a Wasm module with one namespace `env` having
  three imported functions `imported_sum3`, `imported_sumf`, and `imported_void`.

  The imported function `imported_sum3` takes three `:i32` (32 bit integer) arguments and returns a `:i32` number.
  Its implementation is defined by the callback function `fn _context, a, b, c -> a + b + c end`.

      iex> %{store: store, module: module} = TestHelper.wasm_module()
      iex> imports = %{
      ...>   "env" =>
      ...>     %{
      ...>       "imported_sum3" => {:fn, [:i32, :i32, :i32], [:i32], fn _context, a, b, c -> a + b + c end},
      ...>       "imported_sumf" => {:fn, [:f32, :f32], [:f32], fn _context, a, b -> a + b end},
      ...>       "imported_void" => {:fn, [], [], fn _context -> nil end}
      ...>     }
      ...> }
      ...> links = []
      iex> {:ok, %Wasmex.Instance{}} = Wasmex.Instance.new(store, module, imports, links)
  """
  @spec new(
          Wasmex.StoreOrCaller.t(),
          Wasmex.Module.t(),
          %{optional(binary()) => (... -> any())},
          [%{optional(binary()) => Wasmex.Module.t()}] | []
        ) ::
          {:ok, __MODULE__.t()} | {:error, binary()}
  def new(store_or_caller, module, imports, links \\ [])
      when is_map(imports) and is_list(links) do
    %Wasmex.StoreOrCaller{resource: store_or_caller_resource} = store_or_caller
    %Wasmex.Module{resource: module_resource} = module

    links =
      links
      |> Enum.map(fn %{name: name, module: module} ->
        %{name: name, module_resource: module.resource}
      end)

    case Wasmex.Native.instance_new(store_or_caller_resource, module_resource, imports, links) do
      {:error, err} -> {:error, err}
      resource -> {:ok, __wrap_resource__(resource)}
    end
  end

  @doc ~S"""
  Whether the Wasm `instance` exports a function with the given `name`.

  ## Example

      iex> %{store: store, module: module} = TestHelper.wasm_module()
      iex> {:ok, instance} = Wasmex.Instance.new(store, module, %{})
      iex> Wasmex.Instance.function_export_exists(store, instance, "sum")
      true
      iex> Wasmex.Instance.function_export_exists(store, instance, "does_not_exist")
      false
  """
  @spec function_export_exists(Wasmex.StoreOrCaller.t(), __MODULE__.t(), binary()) ::
          boolean()
  def function_export_exists(store_or_caller, instance, name) when is_binary(name) do
    %Wasmex.StoreOrCaller{resource: store_or_caller_resource} = store_or_caller
    %__MODULE__{resource: instance_resource} = instance

    Wasmex.Native.instance_function_export_exists(
      store_or_caller_resource,
      instance_resource,
      name
    )
  end

  @doc ~S"""
  Calls a function the given `name` exported by the Wasm `instance` with the given `params`.

  The Wasm function will be invoked asynchronously in a new OS thread.
  The calling Process/GenServer will receive a `{:returned_function_call, result, from}`
  message once execution finishes.
  The result either is an `{:error, reason}` or `:ok`.

  `call_exported_function/5` assumes to be called within a GenServer context, it expects a `from` argument
  as given by `c:GenServer.handle_call/3`. `from` is returned unchanged to allow
  the wrapping GenServer to reply to their caller.

  A BadArg exception may be thrown when given unexpected input data.

  ## Function parameters

  Parameters for Wasm functions are automatically casted to Wasm values.
  Note that WebAssembly only knows number datatypes (floats and integers of various sizes).

  You can pass arbitrary data to WebAssembly by writing that data into an instances `Wasmex.Memory`.
  The `memory/2` function returns the instances memory.

  ## Example

      iex> %{store: store, module: module} = TestHelper.wasm_module()
      iex> {:ok, instance} = Wasmex.Instance.new(store, module, %{})
      iex> Wasmex.Instance.call_exported_function(store, instance, "sum", [1, 2], :from)
      :ok
      iex> receive do
      ...>   {:returned_function_call, {:ok, [3]}, :from} -> :ok
      ...> after
      ...>  1000 -> raise "message_expected"
      ...> end
  """
  @spec call_exported_function(
          Wasmex.StoreOrCaller.t(),
          __MODULE__.t(),
          binary(),
          [any()],
          GenServer.from()
        ) ::
          :ok | {:error, binary()}
  def call_exported_function(store_or_caller, instance, name, params, from)
      when is_binary(name) do
    %{resource: store_or_caller_resource} = store_or_caller
    %__MODULE__{resource: instance_resource} = instance

    Wasmex.Native.instance_call_exported_function(
      store_or_caller_resource,
      instance_resource,
      name,
      params,
      from
    )
  end

  @doc ~S"""
  Returns the `Wasmex.Memory` of the Wasm `instance`.

  ## Example

      iex> %{store: store, module: module} = TestHelper.wasm_module()
      iex> {:ok, instance} = Wasmex.Instance.new(store, module, %{})
      iex> {:ok, %Wasmex.Memory{}} = Wasmex.Instance.memory(store, instance)
  """
  @spec memory(Wasmex.StoreOrCaller.t(), __MODULE__.t()) ::
          {:ok, Wasmex.Memory.t()} | {:error, binary()}
  def memory(store, instance) do
    Wasmex.Memory.from_instance(store, instance)
  end

  @doc ~S"""
  Reads the value of an exported global.

  ## Examples

      iex> wat = "(module
      ...>          (global $answer i32 (i32.const 42))
      ...>          (export \"answer\" (global $answer))
      ...>        )"
      iex> {:ok, store} = Wasmex.Store.new()
      iex> {:ok, module} = Wasmex.Module.compile(store, wat)
      iex> {:ok, instance} = Wasmex.Instance.new(store, module, %{})
      iex> Wasmex.Instance.get_global_value(store, instance, "answer")
      {:ok, 42}
      iex> Wasmex.Instance.get_global_value(store, instance, "not_a_global")
      {:error, "exported global `not_a_global` not found"}
  """
  @spec get_global_value(Wasmex.StoreOrCaller.t(), __MODULE__.t(), binary()) ::
          {:ok, number()} | {:error, binary()}
  def get_global_value(store_or_caller, instance, global_name) do
    %{resource: store_or_caller_resource} = store_or_caller
    %__MODULE__{resource: instance_resource} = instance

    Wasmex.Native.instance_get_global_value(
      store_or_caller_resource,
      instance_resource,
      global_name
    )
    |> case do
      {:error, _reason} = term -> term
      result when is_number(result) -> {:ok, result}
    end
  end

  @doc ~S"""
  Sets the value of an exported mutable global.

  ## Examples

      iex> wat = "(module
      ...>          (global $count (mut i32) (i32.const 0))
      ...>          (export \"count\" (global $count))
      ...>        )"
      iex> {:ok, store} = Wasmex.Store.new()
      iex> {:ok, module} = Wasmex.Module.compile(store, wat)
      iex> {:ok, instance} = Wasmex.Instance.new(store, module, %{})
      iex> Wasmex.Instance.set_global_value(store, instance, "count", 1)
      :ok
      iex> Wasmex.Instance.get_global_value(store, instance, "count")
      {:ok, 1}
  """
  @spec set_global_value(Wasmex.StoreOrCaller.t(), __MODULE__.t(), binary(), number()) ::
          {:ok, number()} | {:error, binary()}
  def set_global_value(store_or_caller, instance, global_name, new_value) do
    %{resource: store_or_caller_resource} = store_or_caller
    %__MODULE__{resource: instance_resource} = instance

    Wasmex.Native.instance_set_global_value(
      store_or_caller_resource,
      instance_resource,
      global_name,
      new_value
    )
    |> case do
      {} -> :ok
      {:error, _reason} = term -> term
    end
  end
end

defimpl Inspect, for: Wasmex.Instance do
  import Inspect.Algebra

  def inspect(dict, opts) do
    concat(["#Wasmex.Instance<", to_doc(dict.reference, opts), ">"])
  end
end
