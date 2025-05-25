defmodule Wasmex.Wat do
  @moduledoc """
  Utilities to work with Web Assembly Text (.wat) files.
  """

  @doc """
  Converts a Wasm text file to a Wasm binary.
  """
  def to_wasm(wat) do
    case Wasmex.Native.wat_to_wasm(wat) do
      {:error, error} -> {:error, error}
      wasm -> {:ok, wasm}
    end
  end
end
