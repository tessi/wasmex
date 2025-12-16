defmodule Wasmex.Components.FieldConverter do
  @moduledoc """
  Converts field names between Elixir's snake_case and WIT's kebab-case conventions.

  This module provides bidirectional conversion for field names in maps and nested
  data structures, allowing seamless interaction between Elixir code and WebAssembly
  components that use different naming conventions.
  """

  def maybe_convert_args(args, true), do: to_wit(args)
  def maybe_convert_args(args, false), do: args

  def maybe_convert_result({:ok, result}, true), do: {:ok, to_elixir(result)}
  def maybe_convert_result({:ok, result}, false), do: {:ok, result}
  def maybe_convert_result({:error, error}, _), do: {:error, error}

  def to_wit(list) when is_list(list) do
    list |> Enum.map(&to_wit/1)
  end

  def to_wit(map) when is_map(map) do
    map |> Enum.map(&to_wit/1) |> Enum.into(%{})
  end

  def to_wit({key, value}) do
    {identifier_elixir_to_wit(key), value}
  end

  def to_wit(other), do: other

  def to_elixir(list) when is_list(list) do
    list |> Enum.map(&to_elixir/1)
  end

  def to_elixir(map) when is_map(map) do
    map |> Enum.map(&to_elixir/1) |> Enum.into(%{})
  end

  def to_elixir({key, value}) do
    {identifier_wit_to_elixir(key), value}
  end

  def to_elixir(other), do: other

  @doc """
  Converts a WIT identifier (string or atom) to an Elixir atom by replacing
  hyphens with underscores.

  Examples:

      iex> Wasmex.Components.FieldConverter.identifier_wit_to_elixir("get-value")
      :get_value

      iex> Wasmex.Components.FieldConverter.identifier_wit_to_elixir(:is-in-range)
      :is_in_range
  """
  def identifier_wit_to_elixir(identifier) when is_binary(identifier) do
    identifier
    |> String.replace("-", "_")
    |> String.to_atom()
  end

  def identifier_wit_to_elixir(identifier) when is_atom(identifier) do
    identifier
    |> Atom.to_string()
    |> String.replace("-", "_")
    |> String.to_atom()
  end

  @doc """
  Converts an Elixir identifier (string or atom) to a WIT-compatible string by replacing
  underscores with hyphens.

  Examples:

      iex> Wasmex.Components.FieldConverter.identifier_elixir_to_wit(:get_value)
      "get-value"

      iex> Wasmex.Components.FieldConverter.identifier_elixir_to_wit("is_in_range")
      "is-in-range"
  """
  def identifier_elixir_to_wit(identifier) when is_atom(identifier) do
    identifier
    |> Atom.to_string()
    |> String.replace("_", "-")
  end

  def identifier_elixir_to_wit(identifier) when is_binary(identifier) do
    String.replace(identifier, "_", "-")
  end
end
