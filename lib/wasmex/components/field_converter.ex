defmodule Wasmex.Components.FieldConverter do
  @moduledoc """
  Converts field names between Elixir's snake_case and WIT's kebab-case conventions.

  This module provides bidirectional conversion for field names in maps and nested
  data structures, allowing seamless interaction between Elixir code and WebAssembly
  components that use different naming conventions.
  """

  def maybe_convert_args(args, true), do: to_wit(args)
  def maybe_convert_args(args, false), do: args

  def maybe_convert_result(result, enabled, field_atoms \\ %{})

  def maybe_convert_result({:ok, result}, true, field_atoms),
    do: {:ok, to_elixir(result, field_atoms)}

  def maybe_convert_result({:ok, result}, false, _field_atoms), do: {:ok, result}
  def maybe_convert_result({:error, error}, _, _field_atoms), do: {:error, error}

  def to_wit(list) when is_list(list) do
    list |> Enum.map(&to_wit/1)
  end

  def to_wit({key, value}) when is_atom(key) do
    {to_wit_key(key), map_keys(value, &to_wit_map_key/2)}
  end

  def to_wit(other), do: map_keys(other, &to_wit_map_key/2)

  # Only trusted compile-time WIT metadata may supply atoms. Without a schema,
  # keep field names as strings regardless of the VM's existing atom table.
  def to_elixir(value, field_atoms \\ %{})

  def to_elixir(%_{} = struct, _field_atoms), do: struct

  def to_elixir(map, field_atoms) when is_map(map) do
    Map.new(map, fn {key, value} ->
      name = if is_atom(key), do: Atom.to_string(key), else: key
      {Map.get(field_atoms, name, name), to_elixir(value, field_atoms)}
    end)
  end

  def to_elixir(list, field_atoms) when is_list(list) do
    Enum.map(list, &to_elixir(&1, field_atoms))
  end

  def to_elixir(tuple, field_atoms) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.map(&to_elixir(&1, field_atoms)) |> List.to_tuple()
  end

  def to_elixir(other, _field_atoms), do: other

  defp map_keys(%_{} = struct, _convert), do: struct

  defp map_keys(map, convert) when is_map(map) do
    Map.new(map, fn {key, value} ->
      converted_key = convert.(key, map)
      value = Map.get(map, converted_key, value)
      {converted_key, map_keys(value, convert)}
    end)
  end

  defp map_keys(list, convert) when is_list(list), do: Enum.map(list, &map_keys(&1, convert))

  defp map_keys(tuple, convert) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.map(&map_keys(&1, convert)) |> List.to_tuple()
  end

  defp map_keys(value, _convert), do: value

  defp to_wit_key(key) when is_atom(key), do: key |> Atom.to_string() |> String.replace("_", "-")

  defp to_wit_map_key(key, map) when is_atom(key) do
    name = to_wit_key(key)

    if name != Atom.to_string(key) and (Map.has_key?(map, name) or has_atom_key?(map, name)) do
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
end
