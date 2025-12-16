defmodule Wasmex.Engine do
  @moduledoc ~S"""
  An `Engine` which is a global context for compilation and management of Wasm
  modules.

  Engines store global configuration preferences such as compilation settings,
  enabled features, etc. You'll likely only need at most one of these for a
  program.

  You can create an engine with default configuration settings using
  `EngineConfig::default()`. Be sure to consult the documentation of
  `Wasmex.EngineConfig` for default settings.

  ## Example

      iex> {:ok, _engine} = Wasmex.Engine.new(%Wasmex.EngineConfig{})
  """

  alias Wasmex.EngineConfig

  @type t :: %__MODULE__{
          resource: binary(),
          reference: reference()
        }

  defstruct resource: nil,
            # The actual NIF store resource.
            # Normally the compiler will happily do stuff like inlining the
            # resource in attributes. This will convert the resource into an
            # empty binary with no warning. This will make that harder to
            # accidentally do.
            reference: nil

  def __wrap_resource__(resource) do
    %__MODULE__{
      resource: resource,
      reference: make_ref()
    }
  end

  @doc ~S"""
  Creates a new `Wasmex.Engine` with the specified options.

  ## Example

      iex> {:ok, _engine} = Wasmex.Engine.new(%Wasmex.EngineConfig{})
  """
  @spec new(EngineConfig.t()) :: {:ok, __MODULE__.t()} | {:error, binary()}
  def new(%EngineConfig{} = config) do
    case Wasmex.Native.engine_new(config) do
      {:error, err} -> {:error, err}
      resource -> {:ok, __wrap_resource__(resource)}
    end
  end

  @doc ~S"""
  Creates a new `Wasmex.Engine` with default settings.

  ## Example

      iex> _engine = Wasmex.Engine.default()
  """
  @spec default() :: __MODULE__.t()
  def default() do
    {:ok, engine} = new(%EngineConfig{})
    engine
  end

  @doc ~S"""
  Ahead-of-time (AOT) compiles a WebAssembly module.

  The `bytes` provided must be in one of two formats:

  * A [binary-encoded][binary] WebAssembly module
  * A [text-encoded][text] instance of the WebAssembly text format

  This function may be used to compile a module for use with a
  different target host. The output of this function may be used with
  `Wasmex.Module.unsafe_deserialize/2` on hosts compatible with the
  `Wasmex.EngineConfig` associated with this `Wasmex.Engine`.

  The output of this function is safe to send to another host machine
  for later execution. As the output is already a compiled module,
  translation and code generation will be skipped and this will
  improve the performance of constructing a `Wasmex.Module` from
  the output of this function.

  [binary]: https://webassembly.github.io/spec/core/binary/index.html
  [text]: https://webassembly.github.io/spec/core/text/index.html

  ## Example

      iex> {:ok, engine} = Wasmex.Engine.new(%Wasmex.EngineConfig{})
      iex> bytes = File.read!(TestHelper.wasm_test_file_path())
      iex> {:ok, _serialized_module} = Wasmex.Engine.precompile_module(engine, bytes)
  """
  @spec precompile_module(__MODULE__.t(), binary()) :: {:ok, binary()} | {:error, binary()}
  def precompile_module(%__MODULE__{resource: resource}, bytes) do
    case Wasmex.Native.engine_precompile_module(resource, bytes) do
      {:error, err} -> {:error, err}
      serialized_module -> {:ok, serialized_module}
    end
  end
end

defimpl Inspect, for: Wasmex.Engine do
  import Inspect.Algebra

  def inspect(dict, opts) do
    concat(["#Wasmex.Engine<", to_doc(dict.reference, opts), ">"])
  end
end
