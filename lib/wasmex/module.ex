defmodule Wasmex.Module do
  @moduledoc ~S"""
  A compiled WebAssembly module.

  A WASM Module contains stateless WebAssembly code that has
  already been compiled and can be instantiated multiple times.
  """

  @type t :: %__MODULE__{
          resource: binary(),
          reference: reference()
        }

  defstruct resource: nil,
            # The actual NIF module resource.
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
  Compiles a WASM module from it's WASM (a .wasm file) or WAT (a .wat file) representation.

  Compiled modules can be instantiated using `Wasmex.start_link/1` or `Instance.new/3`.

  Since module compilation takes time and resources but instantiation is
  comparatively cheap, it may be a good idea to compile a module once and
  instantiate it often if you want to run a WASM binary multiple times.

  ## Example

  Read a WASM file and compile it into a WASM module.
  Use the compiled module to start a running `Wasmex.Instance`.

      iex> {:ok, store} = Wasmex.Store.new()
      iex> {:ok, module} = Wasmex.Module.compile(store, File.read!(TestHelper.wasm_test_file_path()))
      iex> {:ok, _pid} = Wasmex.start_link(%{store: store, module: module})

  Modules can be compiled from WAT (WebAssembly Text) format:

      iex> wat = "(module)" # minimal and not very useful
      iex> {:ok, store} = Wasmex.Store.new()
      iex> {:ok, %Wasmex.Module{}} = Wasmex.Module.compile(store, wat)
  """
  @spec compile(Wasmex.StoreOrCaller.t(), binary()) ::
          {:ok, __MODULE__.t()} | {:error, binary()}
  def compile(%Wasmex.StoreOrCaller{resource: store_or_caller_resource}, bytes)
      when is_binary(bytes) do
    case Wasmex.Native.module_compile(store_or_caller_resource, bytes) do
      {:ok, resource} -> {:ok, __wrap_resource__(resource)}
      {:error, err} -> {:error, err}
    end
  end

  @doc ~S"""
  Returns the name of the current module if a name is given.

  This name is normally set in the WASM bytecode by some compilers.

  ## Example

      iex> {:ok, store} = Wasmex.Store.new()
      iex> wat = "(module $hiFromTheDocs)" # minimal and not very useful WASM module
      iex> {:ok, module} = Wasmex.Module.compile(store, wat)
      iex> Wasmex.Module.name(module)
      "hiFromTheDocs"
  """
  @spec name(__MODULE__.t()) :: binary() | nil
  def name(%__MODULE__{resource: resource}) do
    case Wasmex.Native.module_name(resource) do
      {:error, _} -> nil
      name -> name
    end
  end

  @doc ~S"""
  Lists all exports of a WASM module.

  Returns a map which has the exports name (string) as key and export info-tuples as values.
  Info tuples always start with an atom indicating the exports type:

  * `:fn` (function)
  * `:global`
  * `:table`
  * `:memory`

  Further parts of the info tuple vary depending on the type.

  ## Example

  List the exported function "hello_world()" of a WASM module:

      iex> {:ok, store} = Wasmex.Store.new()
      iex> wat = "(module
      ...>          (func $helloWorld (result i32) (i32.const 42))
      ...>          (export \"hello_world\" (func $helloWorld))
      ...>        )"
      iex> {:ok, module} = Wasmex.Module.compile(store, wat)
      iex> Wasmex.Module.exports(module)
      %{
        "hello_world" => {:fn, [], [:i32]},
      }
  """
  @spec exports(__MODULE__.t()) :: %{String.t() => any()}
  def exports(%__MODULE__{resource: resource}) do
    Wasmex.Native.module_exports(resource)
  end

  @doc ~S"""
  Lists all imports of a WebAssembly module grouped by their module namespace.

  Returns a map of namespace names to namespaces with each namespace being a map again.
  A namespace is a map of imports with the import name as key and and info-tuple as value.

  Info tuples always start with an atom indicating the imports type:

  * `:fn` (function)
  * `:global`
  * `:table`
  * `:memory`

  Further parts of the info tuple vary depending on the type.

  ## Example

  Show that the WASM module imports a function "inspect" from the "IO" namespace:

      iex> {:ok, store} = Wasmex.Store.new()
      iex> wat = "(module
      ...>          (import \"IO\" \"inspect\" (func $log (param i32)))
      ...>        )"
      iex> {:ok, module} = Wasmex.Module.compile(store, wat)
      iex> Wasmex.Module.imports(module)
      %{
        "IO" => %{
          "inspect" => {:fn, [:i32], []},
        }
      }
  """
  @spec imports(__MODULE__.t()) :: %{String.t() => any()}
  def imports(%__MODULE__{resource: resource}) do
    Wasmex.Native.module_imports(resource)
  end

  @doc ~S"""
  Serializes a compiled WASM module into a binary.

  The generated binary can be deserialized back into a module using `unsafe_deserialize/1`.
  It is unsafe do alter the binary in any way. See `unsafe_deserialize/1` for safety considerations.

  ## Example

  Serializes a compiled module:

      iex> {:ok, store} = Wasmex.Store.new()
      iex> {:ok, module} = Wasmex.Module.compile(store, File.read!(TestHelper.wasm_test_file_path()))
      iex> {:ok, serialized} = Wasmex.Module.serialize(module)
      iex> is_binary(serialized)
      true
  """
  @spec serialize(__MODULE__.t()) :: {:ok, binary()} | {:error, binary()}
  def serialize(%__MODULE__{resource: resource}) do
    case Wasmex.Native.module_serialize(resource) do
      {:error, err} -> {:error, err}
      binary -> {:ok, binary}
    end
  end

  @doc ~S"""
  Deserializes a module from its binary representation.

  This function is inherently unsafe as the provided binary
    1. is going to be deserialized directly into Rust objects
    2. contains the WASM function assembly bodies and, if intercepted, a malicious
       actor could inject code into executable memory.

  Only pass binaries directly coming from `serialize/1`, never any user input.
  Best case is it crashing the NIF, worst case is malicious input doing... malicious things.

  The deserialization must be done on the same CPU architecture as the serialization
  (e.g. don't serialize a x86_64-compiled module and deserialize it on ARM64).

  ## Example

  Serializes a compiled module and deserializes it again:

      iex> {:ok, store} = Wasmex.Store.new()
      iex> {:ok, module} = Wasmex.Module.compile(store, File.read!(TestHelper.wasm_test_file_path()))
      iex> {:ok, serialized} = Wasmex.Module.serialize(module)
      iex> {:ok, %Wasmex.Module{}} = Wasmex.Module.unsafe_deserialize(serialized)
  """
  @spec unsafe_deserialize(binary()) :: {:ok, __MODULE__.t()} | {:error, binary()}
  def unsafe_deserialize(bytes) when is_binary(bytes) do
    case Wasmex.Native.module_unsafe_deserialize(bytes) do
      {:ok, resource} -> {:ok, __wrap_resource__(resource)}
      {:error, err} -> {:error, err}
    end
  end
end

defimpl Inspect, for: Wasmex.Module do
  import Inspect.Algebra

  def inspect(dict, opts) do
    concat(["#Wasmex.Module<", to_doc(dict.reference, opts), ">"])
  end
end
