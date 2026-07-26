defmodule Wasmex.Utils do
  @moduledoc """
  Utility functions for Wasmex.
  """

  @doc """
  Stringifies the keys of a struct or map.
  """
  def stringify_keys(struct) when is_struct(struct), do: struct

  def stringify_keys(map) when is_map(map) do
    for {key, val} <- map, into: %{}, do: {stringify(key), stringify_keys(val)}
  end

  def stringify_keys(list) when is_list(list) do
    for val <- list, into: [], do: stringify_keys(val)
  end

  def stringify_keys(value), do: value

  def stringify(s) when is_binary(s), do: s
  def stringify(s) when is_atom(s), do: Atom.to_string(s)

  @doc false
  def native_timeout(:infinity), do: nil
  def native_timeout(timeout), do: timeout

  @doc false
  def native_request(request) when is_function(request, 1) do
    reference = make_ref()
    :ok = request.({self(), reference})

    receive do
      {^reference, result} -> result
    end
  end
end
