defmodule HelloWorld do
  @moduledoc false

  use Wasmex.Components.ComponentServer,
    wit: "test/component_fixtures/hello_world/hello-world.wit",
    imports: %{
      "greeter" => {:fn, &greeter/0}
    }

  def greeter(), do: "a function defined in the module"
end
