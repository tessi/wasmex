defmodule Wasmex.Components.Component do
  @moduledoc """
  A WebAssembly Component that can be instantiated.

  Components are compiled WebAssembly modules that follow the Component Model specification.
  They define imports and exports using WIT (WebAssembly Interface Types).
  """

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
end
