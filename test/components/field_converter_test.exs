defmodule Wasmex.Components.FieldConverterTest do
  use ExUnit.Case, async: true
  alias Wasmex.Components.FieldConverter

  test "untrusted field names remain strings independently of existing atoms" do
    field = "guest-#{System.unique_integer([:positive])}-field"
    normalized = String.replace(field, "-", "_")

    assert_raise ArgumentError, fn -> String.to_existing_atom(field) end
    assert_raise ArgumentError, fn -> String.to_existing_atom(normalized) end
    input = %{field => "value"}
    assert {:ok, ^input} = FieldConverter.maybe_convert_result({:ok, input}, true)
    assert_raise ArgumentError, fn -> String.to_existing_atom(field) end
    assert_raise ArgumentError, fn -> String.to_existing_atom(normalized) end

    atom = String.to_atom(field)
    _ = String.to_atom(normalized)
    assert {:ok, ^input} = FieldConverter.maybe_convert_result({:ok, input}, true)
    assert {:ok, ^input} = FieldConverter.maybe_convert_result({:ok, %{atom => "value"}}, true)
  end

  test "trusted record and flag keys convert inside lists and tuple payloads" do
    fields = %{"kebab-field" => :kebab_field, "enabled-flag" => :enabled_flag}
    input = {"kebab-field", [%{"kebab-field" => {:ok, %{"enabled-flag" => true}}}]}
    expected = {"kebab-field", [%{kebab_field: {:ok, %{enabled_flag: true}}}]}

    assert {:ok, ^expected} = FieldConverter.maybe_convert_result({:ok, input}, true, fields)
    assert [^input] = FieldConverter.maybe_convert_args([expected], true)
  end

  test "disabled conversion and errors preserve their values" do
    input = %{"kebab-field" => "value"}
    fields = %{"kebab-field" => :kebab_field}
    assert {:ok, ^input} = FieldConverter.maybe_convert_result({:ok, input}, false, fields)
    assert {:error, ^input} = FieldConverter.maybe_convert_result({:error, input}, true, fields)
  end

  test "resource structs retain their native representation" do
    resource = %URI{path: "opaque-resource"}
    input = %{"kebab-field" => resource}

    assert {:ok, %{kebab_field: ^resource}} =
             FieldConverter.maybe_convert_result({:ok, input}, true, %{
               "kebab-field" => :kebab_field
             })
  end

  test "argument conversion retains canonical key precedence" do
    input = [%{"kebab-field" => "canonical", kebab_field: "alias"}]

    assert [%{"kebab-field" => "canonical"}] = FieldConverter.maybe_convert_args(input, true)

    input = [%{"outer" => %{"inner-field": "canonical", inner_field: "alias"}}]

    assert [%{"outer" => %{"inner-field" => "canonical"}}] =
             FieldConverter.maybe_convert_args(input, true)

    input = [%{"kebab-field" => "canonical", "kebab-field": "alias"}]

    assert [%{"kebab-field" => "canonical"}] = FieldConverter.maybe_convert_args(input, true)
  end

  test "flag aliases collapse to the canonical string or atom value" do
    for flags <- [
          %{"is-ready" => true, is_ready: false},
          %{"is-ready": true, is_ready: false},
          %{"is-ready" => true, "is-ready": false, is_ready: false}
        ] do
      assert [%{"is-ready" => true}] = FieldConverter.maybe_convert_args([flags], true)

      assert [%{"nested-flags" => %{"is-ready" => true}}] =
               FieldConverter.maybe_convert_args([%{nested_flags: flags}], true)
    end
  end
end
