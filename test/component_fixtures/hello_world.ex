defmodule HelloWorld do
  @moduledoc false

  use Wasmex.Components.ComponentServer,
    wit: "test/component_fixtures/hello_world/hello-world.wit",
    imports: %{
      "greeter" => {:fn, &greeter/0}
    }

  def init(init_arg) do
    {:ok, init_arg}
  end

  def greeter(), do: "a function defined in the module"
end
