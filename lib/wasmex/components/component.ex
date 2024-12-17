defmodule Wasmex.Components.Component do
  @moduledoc """
  This represents a compiled but not yet instantiated WebAssembly component. It is
  analogous to a Module in core webassembly.
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

  def __wrap_resource__(resource) do
    %__MODULE__{
      resource: resource,
      reference: make_ref()
    }
  end

  def new(store_or_caller, component_bytes) do
    %{resource: store_or_caller_resource} = store_or_caller

    case Wasmex.Native.component_new(store_or_caller_resource, component_bytes) do
      {:error, err} -> {:error, err}
      resource -> {:ok, __wrap_resource__(resource)}
    end
  end

  defmacro __using__(opts) do
    genserver_setup =
      quote do
        use GenServer

        def start_link(opts) do
          Wasmex.Components.start_link(opts)
        end

        def handle_call(request, from, state) do
          Wasmex.Components.handle_call(request, from, state)
        end
      end

    functions =
      if wit_path = Keyword.get(opts, :wit) do
        wit_contents = File.read!(wit_path)
        exported_functions = Wasmex.Native.wit_exported_functions(wit_path, wit_contents)

        for {function, arity} <- exported_functions do
          arglist = Macro.generate_arguments(arity, __MODULE__)
          function_atom = function |> String.replace("-", "_") |> String.to_atom()

          quote do
            def unquote(function_atom)(pid, unquote_splicing(arglist)) do
              Wasmex.Components.call_function(pid, unquote(function), [unquote_splicing(arglist)])
            end
          end
        end
      else
        []
      end

    [genserver_setup, functions]
  end
end
