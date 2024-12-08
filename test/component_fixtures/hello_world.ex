defmodule HelloWorld do
  @moduledoc false

  use Wasmex.Components.Component, wit: "test/component_fixtures/hello_world/hello-world.wit"
end
