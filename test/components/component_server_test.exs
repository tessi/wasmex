defmodule Wasmex.Components.GenServerTest do
  use ExUnit.Case, async: true
  alias Wasmex.Wasi.WasiP2Options

  test "the low-level component call keeps its optional timeout" do
    assert Code.ensure_loaded?(Wasmex.Components.Instance)
    assert function_exported?(Wasmex.Components.Instance, :call_function, 4)
    assert function_exported?(Wasmex.Components.Instance, :call_function, 5)
  end

  test "interacting with a component GenServer" do
    component_bytes = File.read!(TestHelper.component_type_conversions_file_path())

    imports =
      TestHelper.component_type_conversions_import_map()
      |> Map.merge(%{"import-id-string" => {:fn, fn _ -> "Polo" end}})

    component_pid =
      start_supervised!({Wasmex.Components, bytes: component_bytes, imports: imports})

    assert {:ok, "Polo"} =
             Wasmex.Components.call_function(component_pid, "export-id-string", ["Marco!"])

    assert {:error, _error} =
             Wasmex.Components.call_function(component_pid, "non-existent-export", ["wut"])
  end

  test "loading a component from a path" do
    component_pid =
      start_supervised!(
        {Wasmex.Components,
         path: TestHelper.component_type_conversions_file_path(),
         imports: TestHelper.component_type_conversions_import_map()}
      )

    assert {:ok, "Echo"} =
             Wasmex.Components.call_function(component_pid, "export-id-string", ["Echo"])
  end

  test "specifying options as a map" do
    component_pid =
      start_supervised!(
        {Wasmex.Components,
         %{
           path: TestHelper.component_type_conversions_file_path(),
           imports: TestHelper.component_type_conversions_import_map()
         }}
      )

    assert {:ok, "Echo"} =
             Wasmex.Components.call_function(component_pid, "export-id-string", ["Echo"])
  end

  test "using the component server macro" do
    component_bytes = File.read!("test/component_fixtures/hello_world/hello_world.wasm")

    component_pid =
      start_supervised!(
        {HelloWorld, bytes: component_bytes, wasi: %WasiP2Options{allow_http: true}}
      )

    assert {:ok, "Hello, Elixir from a function defined in the module!"} =
             HelloWorld.greet(component_pid, "Elixir")

    assert {:ok, [greeting1, greeting2]} =
             HelloWorld.multi_greet(component_pid, "Elixir", 2)

    assert {:ok, %{kebab_field: "foo"}} =
             HelloWorld.echo_kebab(component_pid, %{kebab_field: "foo"})

    assert greeting1 =~ "Hello"
    assert greeting2 =~ "Hello"
  end

  test "register by name" do
    component_bytes = File.read!(TestHelper.component_type_conversions_file_path())

    {:ok, _pid} =
      start_supervised(
        {Wasmex.Components,
         bytes: component_bytes,
         name: ComponentTypes,
         imports: TestHelper.component_type_conversions_import_map()}
      )

    assert {:ok, "Echo"} =
             Wasmex.Components.call_function(ComponentTypes, "export-id-string", ["Echo"])
  end

  test "field name conversion is enabled by default" do
    component_bytes = File.read!("test/component_fixtures/hello_world/hello_world.wasm")

    component_pid =
      start_supervised!(
        {HelloWorld, bytes: component_bytes, wasi: %WasiP2Options{allow_http: true}}
      )

    # With default conversion enabled, kebab_field should work
    assert {:ok, %{kebab_field: "test"}} =
             HelloWorld.echo_kebab(component_pid, %{kebab_field: "test"})
  end

  test "component result fields cannot create atoms" do
    component_bytes = File.read!("test/component_fixtures/hello_world/hello_world.wasm")
    suffix = Base.encode16(:crypto.strong_rand_bytes(2), case: :lower)
    field = "f#{suffix}-field"
    atom_name = "f#{suffix}_field"
    patched_bytes = :binary.replace(component_bytes, "kebab-field", field, [:global])

    component_pid =
      start_supervised!(
        {HelloWorld, bytes: patched_bytes, wasi: %WasiP2Options{allow_http: true}}
      )

    assert_raise ArgumentError, fn -> String.to_existing_atom(field) end
    assert_raise ArgumentError, fn -> String.to_existing_atom(atom_name) end
    assert {:ok, %{^field => "test"}} = HelloWorld.echo_kebab(component_pid, %{field => "test"})
    assert_raise ArgumentError, fn -> String.to_existing_atom(field) end
    assert_raise ArgumentError, fn -> String.to_existing_atom(atom_name) end

    _ = String.to_atom(field)
    _ = String.to_atom(atom_name)
    assert {:ok, %{^field => "test"}} = HelloWorld.echo_kebab(component_pid, %{field => "test"})
  end

  @tag :tmp_dir
  test "declared fields become atoms without an atom in caller code", %{tmp_dir: tmp_dir} do
    field = "known-field"
    wit = File.read!("test/component_fixtures/hello_world/hello-world.wit")
    wit_path = Path.join(tmp_dir, "hello-world.wit")
    File.write!(wit_path, String.replace(wit, "kebab-field", field))

    assert_raise ArgumentError, fn -> String.to_existing_atom("known_field") end

    {:module, wrapper, _, _} =
      Module.create(
        __MODULE__.DeclaredField,
        quote do
          @convert_field_names true
          use Wasmex.Components.ComponentServer,
            wit: unquote(wit_path),
            convert_field_names: @convert_field_names,
            imports: %{"greeter" => {:fn, &HelloWorld.greeter/0}}

          def init(init_arg), do: {:ok, init_arg}
        end,
        Macro.Env.location(__ENV__)
      )

    assert wit_path in wrapper.__info__(:attributes)[:external_resource]

    component_bytes = File.read!("test/component_fixtures/hello_world/hello_world.wasm")
    patched_bytes = :binary.replace(component_bytes, "kebab-field", field, [:global])

    component_pid =
      start_supervised!({wrapper, bytes: patched_bytes, wasi: %WasiP2Options{allow_http: true}})

    atom_key = String.to_existing_atom("known_field")
    assert {:ok, %{^atom_key => "test"}} = wrapper.echo_kebab(component_pid, %{field => "test"})
  end

  test "nested record keys convert without changing tuple values" do
    alias Wasmex.Components.FieldConverter

    wit_result = {"kebab-field", [%{"kebab-field" => %{"kebab-field" => "test"}}]}
    elixir_result = {"kebab-field", [%{kebab_field: %{kebab_field: "test"}}]}
    fields = %{"kebab-field" => :kebab_field}

    assert {:ok, ^elixir_result} =
             FieldConverter.maybe_convert_result({:ok, wit_result}, true, fields)

    assert [^wit_result] = FieldConverter.maybe_convert_args([elixir_result], true)

    args = [%{"outer" => %{"inner-field": "canonical", inner_field: "alias"}}]

    assert [%{"outer" => %{"inner-field" => "canonical", inner_field: "alias"}}] =
             FieldConverter.maybe_convert_args(args, true)
  end

  test "field conversion does not create an alias for an existing atom key" do
    key = :"kebab-only-key"
    input = %{key => "test"}

    assert_raise ArgumentError, fn -> String.to_existing_atom("kebab_only_key") end

    assert {:ok, ^input} =
             Wasmex.Components.FieldConverter.maybe_convert_result({:ok, input}, true)

    assert_raise ArgumentError, fn -> String.to_existing_atom("kebab_only_key") end
  end

  test "field name conversion can be disabled" do
    component_bytes = File.read!("test/component_fixtures/hello_world/hello_world.wasm")

    component_pid =
      start_supervised!(
        {HelloWorldNoConversion, bytes: component_bytes, wasi: %WasiP2Options{allow_http: true}}
      )

    # With conversion disabled, need to use kebab-field format
    assert {:ok, %{"kebab-field" => "test"}} =
             HelloWorldNoConversion.echo_kebab(component_pid, %{"kebab-field" => "test"})
  end

  test "a callback completing after timeout does not terminate the component server" do
    component_bytes = File.read!("test/component_fixtures/hello_world/hello_world.wasm")

    imports = %{
      "greeter" =>
        {:fn,
         fn ->
           Process.sleep(100)
           "Elixir"
         end}
    }

    component_pid =
      start_supervised!(
        {Wasmex.Components,
         bytes: component_bytes, wasi: %WasiP2Options{allow_http: true}, imports: imports}
      )

    assert catch_exit(Wasmex.Components.call_function(component_pid, "greet", ["World"], 10))
    Process.sleep(150)

    assert Process.alive?(component_pid)

    assert {:ok, "Hello, World from Elixir!"} =
             Wasmex.Components.call_function(component_pid, "greet", ["World"])
  end

  test "an invalid callback result does not terminate the component server" do
    component_bytes = File.read!("test/component_fixtures/hello_world/hello_world.wasm")

    component_pid =
      start_supervised!(
        {Wasmex.Components,
         bytes: component_bytes,
         wasi: %WasiP2Options{allow_http: true},
         imports: %{"greeter" => {:fn, fn -> 42 end}}}
      )

    assert {:error, _reason} =
             Wasmex.Components.call_function(component_pid, "greet", ["World"])

    assert Process.alive?(component_pid)
  end

  test "a callback exception does not terminate the component server" do
    component_bytes = File.read!("test/component_fixtures/hello_world/hello_world.wasm")

    component_pid =
      start_supervised!(
        {Wasmex.Components,
         bytes: component_bytes,
         wasi: %WasiP2Options{allow_http: true},
         imports: %{"greeter" => {:fn, fn -> raise "callback failed" end}}}
      )

    assert {:error, _reason} =
             Wasmex.Components.call_function(component_pid, "greet", ["World"])

    assert Process.alive?(component_pid)
  end
end
