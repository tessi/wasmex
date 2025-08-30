defmodule Wasmex.Components.FieldConverter do
  def to_wit(list) when is_list(list) do
    list |> Enum.map(&to_wit/1)
  end

  def to_wit(map) when is_map(map) do
    map |> Enum.map(&to_wit/1) |> Enum.into(%{})
  end

  def to_wit({key, value}) when is_atom(key) do
    {key |> Atom.to_string() |> String.replace("_", "-"), value}
  end

  def to_wit(other), do: other

  def to_elixir(list) when is_list(list) do
    list |> Enum.map(&to_elixir/1)
  end

  def to_elixir(map) when is_map(map) do
    map |> Enum.map(&to_elixir/1) |> Enum.into(%{})
  end

  def to_elixir({key, value}) when is_atom(key) do
    {key |> Atom.to_string() |> String.replace("-", "_") |> String.to_atom(), value}
  end

  def to_elixir({key, value}) when is_binary(key) do
    {key |> String.replace("-", "_") |> String.to_atom(), value}
  end

  def to_elixir(other), do: other
end
