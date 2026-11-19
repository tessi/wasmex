defmodule Wasmex.Components.Component do
  @moduledoc """
  A WebAssembly Component that can be instantiated.

  Components are compiled WebAssembly modules that follow the Component Model specification.
  They define imports and exports using WIT (WebAssembly Interface Types).
  """

  alias Wasmex.Engine

  @type t :: %__MODULE__{
          resource: binary(),
          reference: reference()
        }

  defstruct resource: nil,
            # The actual NIF component resource.
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

  @doc """
  Compiles a new WebAssembly component from bytes.

  ## Parameters
    * `store` - The store to compile the component for
    * `bytes` - Raw WebAssembly component bytes

  ## Returns
    * `{:ok, component}` on success
    * `{:error, reason}` on failure
  """
  def new(store_or_caller, component_bytes) do
    %{resource: store_or_caller_resource} = store_or_caller

    case Wasmex.Native.component_new(store_or_caller_resource, component_bytes) do
      {:error, err} -> {:error, err}
      resource -> {:ok, __wrap_resource__(resource)}
    end
  end

  @doc """
  Serializes a compiled WebAssembly component into an artifact for
  `unsafe_deserialize/2` or `unsafe_deserialize_file/2`.
  """
  @spec serialize(t()) :: {:ok, binary()} | {:error, binary()}
  def serialize(%__MODULE__{resource: resource}) do
    case Wasmex.Native.component_serialize(resource) do
      {:error, err} -> {:error, err}
      artifact -> {:ok, artifact}
    end
  end

  @doc """
  Loads a component artifact produced by `serialize/1` or
  `Wasmex.Engine.precompile_component/2`.

  The artifact must match the Wasmtime version, target, and compatible
  configuration of the supplied Engine. Create the component Store with
  this same Engine before instantiating the component.

  ## Safety

  Only pass unmodified artifacts from a trusted Wasmtime compiler. The
  artifact contains native executable code. Wasmtime's compatibility checks
  cannot establish that the code is safe to run. Keep this API away from
  untrusted input.
  """
  @spec unsafe_deserialize(binary(), Engine.t()) :: {:ok, t()} | {:error, binary()}
  def unsafe_deserialize(bytes, %Engine{resource: engine_resource}) when is_binary(bytes) do
    case Wasmex.Native.component_unsafe_deserialize(bytes, engine_resource) do
      {:error, err} -> {:error, err}
      resource -> {:ok, __wrap_resource__(resource)}
    end
  end

  @doc """
  Loads a precompiled component by memory-mapping its artifact file.

  The file must contain the output of `serialize/1` or
  `Wasmex.Engine.precompile_component/2` and match the supplied Engine's
  Wasmtime version, target, and configuration. Use the same Engine to create
  the component Store before instantiating the component.

  ## Safety

  Only load unmodified artifacts from a trusted Wasmtime compiler. They
  contain native executable code, and the mapped file must stay unchanged
  for the lifetime of the component and all instances created from it.
  Use a versioned artifact path when deploying updated files.
  """
  @spec unsafe_deserialize_file(String.t(), Engine.t()) :: {:ok, t()} | {:error, binary()}
  def unsafe_deserialize_file(path, %Engine{resource: engine_resource}) when is_binary(path) do
    case Wasmex.Native.component_unsafe_deserialize_file(path, engine_resource) do
      {:error, err} -> {:error, err}
      resource -> {:ok, __wrap_resource__(resource)}
    end
  end
end
