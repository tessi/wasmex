defmodule Wasmex.StoreOrCaller do
  @moduledoc """
  Either a Wasmex.Store or "Caller" for imported functions.

  A Store is a collection of WebAssembly instances and host-defined state, see `Wasmex.Store`.
  A Caller takes the place of a Store in imported function calls. If a Store is needed in
  Elixir-provided imported functions, always use the provided Caller because
  using the Store will cause a deadlock (the running WASM instance locks the Stores Mutex).
  """

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

  @doc false
  def wrap_resource(resource) do
    %__MODULE__{
      resource: resource,
      reference: make_ref()
    }
  end
end

defimpl Inspect, for: Wasmex.StoreOrCaller do
  import Inspect.Algebra

  def inspect(dict, opts) do
    concat(["#Wasmex.StoreOrCaller<", to_doc(dict.reference, opts), ">"])
  end
end
