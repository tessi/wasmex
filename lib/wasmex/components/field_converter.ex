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

  def maybe_convert_result({:ok, result}, true, field_atoms) do
    {:ok,
     map_keys(result, fn key, _map ->
       name = key_name(key)
       Map.get(field_atoms, name, name)
     end)}
  end

  def maybe_convert_result(result, enabled, _field_atoms),
    do: maybe_convert_result(result, enabled)

  def to_wit(list) when is_list(list) do
    list |> Enum.map(&to_wit/1)
  end

  def to_wit({key, value}) when is_atom(key) do
    {to_wit_key(key), map_keys(value, &to_wit_map_key/2)}
  end

  def to_wit(other), do: map_keys(other, &to_wit_map_key/2)

  def to_elixir(list) when is_list(list) do
    list |> Enum.map(&to_elixir/1)
  end

  def to_elixir(map) when is_map(map) do
    map |> Enum.map(&to_elixir/1) |> Enum.into(%{})
  end

  def to_elixir({key, value}) when is_atom(key) or is_binary(key) do
    {normalize_existing_key(key), value}
  end

  def to_elixir(other), do: other

  defp normalize_existing_key(key) do
    key |> key_name() |> String.replace("-", "_") |> String.to_existing_atom()
  rescue
    ArgumentError -> key
  end

  defp map_keys(%_{} = struct, _convert), do: struct

  defp map_keys(map, convert) when is_map(map) do
    Map.new(map, fn {key, value} -> {convert.(key, map), map_keys(value, convert)} end)
  end

  defp map_keys(list, convert) when is_list(list), do: Enum.map(list, &map_keys(&1, convert))

  defp map_keys(tuple, convert) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.map(&map_keys(&1, convert)) |> List.to_tuple()
  end

  defp map_keys(value, _convert), do: value

  defp to_wit_key(key) when is_atom(key), do: key |> Atom.to_string() |> String.replace("_", "-")

  defp to_wit_map_key(key, map) when is_atom(key) do
    name = to_wit_key(key)

    if Map.has_key?(map, name) or (name != Atom.to_string(key) and has_atom_key?(map, name)) do
      key
    else
      name
    end
  end

  defp to_wit_map_key(key, _map), do: key

  defp has_atom_key?(map, name) do
    Map.has_key?(map, String.to_existing_atom(name))
  rescue
    ArgumentError -> false
  end

  defp key_name(key) when is_atom(key), do: Atom.to_string(key)
  defp key_name(key), do: key
end
