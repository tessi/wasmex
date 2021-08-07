defmodule Wasmex.Module do
  @moduledoc """
  A compiled WebAssembly module.

  A WebAssembly Module contains stateless WebAssembly code that has already been compiled and can be instantiated multiple times.

      # Read a WASM file and compile it into a WASM module
      {:ok, bytes } = File.read("wasmex_test.wasm")
      {:ok, module} = Wasmex.Module.compile(bytes)

      # use the compiled module to start as many running instances as you want
      {:ok, instance } = Wasmex.start_link(%{module: module})
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

  @doc """
  Compiles a WASM module from it's WASM (usually a .wasm file) or WAT (usually a .wat file)
  representation.

  Compiled modules can be instantiated using `Wasmex.start_link/1`.
  Since module compilation takes time and resources but instantiation is comparatively cheap, it
  may be a good idea to compile a module once and instantiate it often if you want to
  run a WASM binary multiple times.
  """
  @spec compile(binary()) :: {:ok, __MODULE__.t()} | {:error, binary()}
  def compile(bytes) when is_binary(bytes) do
    case Wasmex.Native.module_compile(bytes) do
      {:ok, resource} -> {:ok, wrap_resource(resource)}
      {:error, err} -> {:error, err}
    end
  end

  @doc """
  Returns the name of the current module if a name is given.

  This name is normally set in the WebAssembly bytecode by some compilers,
  but can be also overwritten using `set_name/2`.
  """
  @spec name(__MODULE__.t()) :: binary() | nil
  def name(%__MODULE__{resource: resource}) do
    case Wasmex.Native.module_name(resource) do
      {:error, _} -> nil
      name -> name
    end
  end

  @doc """
  Sets the name of the current module.

  This is normally useful for stacktraces and debugging.

  It will return `:ok` if the module name was changed successfully,
  and return an `{:error, reason}` tuple otherwise (in case the module is already
  instantiated).
  """
  @spec set_name(__MODULE__.t(), binary()) :: :ok | {:error, binary()}
  def set_name(%__MODULE__{resource: resource}, name) when is_binary(name) do
    Wasmex.Native.module_set_name(resource, name)
  end

  @doc """
  Lists all exports of a WebAssembly module.

  Returns a map which has the exports name (string) as key and export info-tuples as values.
  Info tuples always start with an atom indicating the exports type:

  * `:fn` (function)
  * `:global`
  * `:table`
  * `:memory`

  Further parts of the info tuple vary depending on the type.
  """
  @spec exports(__MODULE__.t()) :: map()
  def exports(%__MODULE__{resource: resource}) do
    Wasmex.Native.module_exports(resource)
  end

  @doc """
  Lists all imports of a WebAssembly module grouped by their module namespace.

  Returns a map of namespaces, each being a map which has the imports name (string)
  as key and import info-tuples as values.
  Info tuples always start with an atom indicating the imports type:

  * `:fn` (function)
  * `:global`
  * `:table`
  * `:memory`

  Further parts of the info tuple vary depending on the type.
  """
  @spec imports(__MODULE__.t()) :: map()
  def imports(%__MODULE__{resource: resource}) do
    Wasmex.Native.module_imports(resource)
  end

  @doc """
  Serializes a compiled WASM module into a binary.

  The generated binary can be deserialized back into a module using `unsafe_deserialize/1`.
  It is unsafe do alter the binary in any way. See `unsafe_deserialize/1` for safety considerations.
  """
  @spec serialize(__MODULE__.t()) :: {:ok, binary()} | {:error, binary()}
  def serialize(%__MODULE__{resource: resource}) do
    case Wasmex.Native.module_serialize(resource) do
      {:error, err} -> {:error, err}
      binary -> {:ok, binary}
    end
  end

  @doc """
  Deserializes a module from its binary representation.

  This function is inherently unsafe as the provided binary:
    1. Is going to be deserialized directly into Rust objects.
    2. Contains the WASM function assembly bodies and, if intercepted, a malicious actor could inject code into executable memory.

  And as such, the deserialize method is unsafe. Only pass binaries directly coming from
  `serialize/1`, never any user input. Best case is it crashing the NIF, worst case is
  malicious input doing... malicious things.

  The deserialization must be done on the same CPU architecture as the serialization
  (e.g. don't serialize a x86_64-compiled module and deserialize it on ARM64).
  """

  @spec unsafe_deserialize(binary()) :: {:ok, __MODULE__.t()} | {:error, binary()}
  def unsafe_deserialize(bytes) when is_binary(bytes) do
    case Wasmex.Native.module_unsafe_deserialize(bytes) do
      {:ok, resource} -> {:ok, wrap_resource(resource)}
      {:error, err} -> {:error, err}
    end
  end

  defp wrap_resource(resource) do
    %__MODULE__{
      resource: resource,
      reference: make_ref()
    }
  end
end

defimpl Inspect, for: Wasmex.Module do
  import Inspect.Algebra

  def inspect(dict, opts) do
    concat(["#Wasmex.Module<", to_doc(dict.reference, opts), ">"])
  end
end
