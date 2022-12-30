defmodule Wasmex.StoreOrCaller do
  @moduledoc """
  TBD
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
