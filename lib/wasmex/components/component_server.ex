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
  package example:greeter

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
  iex> MyApp.Greeter.greet(pid, "World")  # Returns: "Hello, World!"
  iex> MyApp.Greeter.multi_greet(pid, "World", 2) # Returns: ["Hello, World!", "Hello, World!"]
  ```

  ## Imports Example

  When your WebAssembly component imports functions, you can provide them using the `:imports` option.
  For example, given a WIT file `logger.wit`:

  ```wit
  package example:logger

  world logger {
    import log: func(message: string)
    import get-timestamp: func() -> u64

    export log-with-timestamp: func(message: string)
  }
  ```

  You can implement the imported functions like this:

  ```elixir
  defmodule MyApp.Logger do
    use Wasmex.Components.ComponentServer,
      wit: "path/to/logger.wit",
      imports: %{
        "log" => fn message ->
          IO.puts(message)
          :ok
        end,
        "get-timestamp" => fn ->
          System.system_time(:second)
        end
      }
  end
  ```

  # Usage:
  ```elixir
  iex> {:ok, pid} = MyApp.Logger.start_link(wasm: "path/to/logger.wasm")
  iex> MyApp.Logger.log_with_timestamp(pid, "Hello from Wasm!")
  ```

  The import functions should return the correct types as defined in the WIT file. Incorrect types will likely
  cause a crash, or possibly a NIF panic.

  ## Options

  * `:wit` - Path to the WIT file defining the component's interface
  * `:convert_field_names` - All function calls will for all arugments
  recursively convert any map field names from under_score case to kebab-case
  and vice versa for return values. Defaults to true.
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
        exported_functions = Wasmex.Native.wit_exported_functions(wit_path, wit_contents)

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
                unquote(convert_field_names?)
              )
            end
          end
        end
      else
        []
      end

    [genserver_setup, functions]
  end
end
