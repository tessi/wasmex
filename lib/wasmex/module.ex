defmodule Wasmex.Module do
  @moduledoc """
  A compiled WebAssembly module.

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

  @spec compile(binary()) :: {:error, binary()} | {:ok, __MODULE__.t()}
  def compile(bytes) when is_binary(bytes) do
    case Wasmex.Native.module_compile(bytes) do
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
