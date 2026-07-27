defmodule Wasmex.Components.WasiHostResourceE2ETest do
  use ExUnit.Case, async: true

  alias Wasmex.Components
  alias Wasmex.Components.HostResource

  @app_interface "demo:wasi-error/app@1.0.0"
  @factory_interface "demo:wasi-error/factory@1.0.0"
  @wasi_error_interface "wasi:io/error@0.2.12"

  defmodule WasiErrorHost do
    use Wasmex.Components.HostResource,
      wit_path: TestHelper.wasi_host_resource_component_wit_path(),
      resource: "error",
      interface: "wasi:io/error@0.2.12"

    def to_debug_string(%{message: message}), do: "elixir-host-error: #{message}"

    def drop(%{message: message, owner: owner}) do
      send(owner, {:wasi_error_dropped, message})
      :ok
    end
  end

  test "shadows the built-in WASI resource with an Elixir host resource" do
    owner = self()

    factory_imports = %{
      @factory_interface => %{
        "make-error" => {:fn, fn message -> %{message: message, owner: owner} end}
      }
    }

    imports = HostResource.merge_imports([WasiErrorHost, factory_imports])

    component =
      start_supervised!(
        {Components,
         bytes: File.read!(TestHelper.wasi_host_resource_component_file_path()), imports: imports}
      )

    assert {:ok, "elixir-host-error: boom"} =
             Components.call_function(component, [@app_interface, "describe"], ["boom"])

    assert_receive {:wasi_error_dropped, "boom"}

    assert %{
             @wasi_error_interface => %{
               "error" => {:resource, _drop},
               "[method]error.to-debug-string" => {:fn, _method}
             }
           } = WasiErrorHost.imports()

    external_resources =
      WasiErrorHost.module_info(:attributes)
      |> Keyword.get_values(:external_resource)
      |> List.flatten()

    wit_path = TestHelper.wasi_host_resource_component_wit_path()
    assert Path.join(wit_path, "world.wit") in external_resources
    assert Path.join(wit_path, "deps/io.wit") in external_resources
  end
end
