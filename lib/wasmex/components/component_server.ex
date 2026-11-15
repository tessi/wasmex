defmodule Wasmex.Components.ComponentServer do
  @moduledoc """
  A GenServer wrapper for WebAssembly components. This module provides a macro to easily
  create GenServer-based components with wrapper functions for the exports in the WIT definition.

  ## Usage

  To use this module, you need to:
  1. Create a WIT file defining your component's interface
  2. Create a module that uses ComponentServer with the path to your WIT file
  3. Use the generated functions to interact with your WebAssembly component

  ## Basic Example

  Given a WIT file `greeter.wit` with the following content:

  ```wit
  package example:greeter;

  world greeter {
    export greet: func(who: string) -> string;
    export multi-greet: func(who: string, times: u16) -> list<string>;
  }
  ```

  You can create a GenServer wrapper like this:

  ```elixir
  defmodule MyApp.Greeter do
    use Wasmex.Components.ComponentServer,
      wit: "path/to/greeter.wit"
  end
  ```

  This will automatically generate the following functions:

  ```elixir
  # Start the component server
  iex> {:ok, pid} = MyApp.Greeter.start_link(path: "path/to/greeter.wasm")

  # Generated function wrappers:
  iex> MyApp.Greeter.greet(pid, "World")  # Returns: {:ok, "Hello, World!"}
  iex> MyApp.Greeter.multi_greet(pid, "World", 2) # Returns: {:ok, ["Hello, World!", "Hello, World!"]}
  ```

  ## Imports Example

  When your WebAssembly component imports functions, you can provide them using the `:imports` option.
  For example, given a WIT file `logger.wit`:

  ```wit
  package example:logger;

  world logger {
    import log: func(message: string);
    import get-timestamp: func() -> u64;

    export log-with-timestamp: func(message: string);
  }
  ```

  You can implement the imported functions like this:

  ```elixir
  defmodule MyApp.Logger do
    use Wasmex.Components.ComponentServer,
      wit: "path/to/logger.wit",
      imports: %{
        "log" => {:fn, fn message ->
          IO.puts(message)
        end},
        "get-timestamp" => {:fn, fn ->
          System.system_time(:second)
        end}
      }
  end
  ```

  # Usage:
  ```elixir
  iex> {:ok, pid} = MyApp.Logger.start_link(path: "path/to/logger.wasm")
  iex> MyApp.Logger.log_with_timestamp(pid, "Hello from Wasm!")
  ```

  Import functions must return the types defined in the WIT file. An incompatible
  return value traps the component call and is returned as an error.

  ## Options

  * `:wit` - Path to the WIT file defining the component's interface
  * `:convert_field_names` - Recursively converts atom keys in arguments from
  snake_case to kebab-case. Returned record and flag keys declared in the
  compile-time WIT become snake_case atoms if they fit the BEAM atom length
  limit. Other keys are strings with their original spelling. Defaults to true.
  * `:imports` - A map of import function implementations that the component requires, where each key
    is the function name as defined in the WIT file and the value is the implementing function
  """

  defmacro __using__(opts) do
    macro_imports = Keyword.get(opts, :imports, Macro.escape(%{}))
    convert_field_names? = Keyword.get(opts, :convert_field_names, true)

    genserver_setup =
      quote do
        use GenServer

        def start_link(opts) do
          Wasmex.Components.start_link(opts |> Keyword.put(:imports, unquote(macro_imports)))
        end

        def handle_call(request, from, state) do
          Wasmex.Components.handle_call(request, from, state)
        end
      end

    functions =
      if wit_path = Keyword.get(opts, :wit) do
        wit_contents = File.read!(wit_path)

        {exported_functions, field_names} =
          Wasmex.Native.wit_component_server_metadata(wit_path, wit_contents)

        field_atoms = compile_field_atoms(field_names, convert_field_names?)

        external_resource = quote do: @external_resource(unquote(Path.expand(wit_path)))

        wrappers =
          for {function, arity} <- exported_functions do
            arglist = Macro.generate_arguments(arity, __MODULE__)
            function_atom = function |> String.replace("-", "_") |> String.to_atom()

            quote do
              def unquote(function_atom)(pid, unquote_splicing(arglist)) do
                args = [unquote_splicing(arglist)]

                converted_args =
                  Wasmex.Components.FieldConverter.maybe_convert_args(
                    args,
                    unquote(convert_field_names?)
                  )

                result = Wasmex.Components.call_function(pid, unquote(function), converted_args)

                Wasmex.Components.FieldConverter.maybe_convert_result(
                  result,
                  unquote(convert_field_names?),
                  unquote(Macro.escape(field_atoms))
                )
              end
            end
          end

        [external_resource | wrappers]
      else
        []
      end

    [genserver_setup, functions]
  end

  defp compile_field_atoms(_field_names, false), do: %{}

  defp compile_field_atoms(field_names, _convert_field_names) do
    for name <- field_names, byte_size(name) <= 255, into: %{} do
      {name, name |> String.replace("-", "_") |> String.to_atom()}
    end
  end
end
