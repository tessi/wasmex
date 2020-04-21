defmodule Wasmex.CallbackToken do
  @moduledoc """
  TBD
  """

  @type t :: %__MODULE__{
          resource: binary(),
          reference: reference()
        }

  defstruct resource: nil,
            # The actual NIF CallbackToken resource.
            # Normally the compiler will happily do stuff like inlining the
            # resource in attributes. This will convert the resource into an
            # empty binary with no warning. This will make that harder to
            # accidentally do.
            # It also serves as a handy way to tell file handles apart.
            reference: nil

  def wrap_resource(resource) do
    %__MODULE__{
      resource: resource,
      reference: make_ref(),
    }
  end
end

defimpl Inspect, for: Wasmex.CallbackToken do
  import Inspect.Algebra

  def inspect(dict, opts) do
    concat(["#Wasmex.CallbackToken<", to_doc(dict.reference, opts), ">"])
  end
end
