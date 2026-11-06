defmodule Wasmex.Wat do
  @moduledoc """
  Utilities to work with Web Assembly Text (.wat) files.
  """

  @doc """
  Converts a Wasm text file to a Wasm binary.

  Component WAT uses nested core references in canonical ABI options, such as
  `(memory (core memory $instance "mem"))` and `(realloc (core func $realloc))`.
  To temporarily accept legacy component references, set
  `WAST_STRICT_COMPONENT_INDICES=0` before starting the VM.
  """
  def to_wasm(wat) do
    case Wasmex.Native.wat_to_wasm(wat) do
      {:error, error} -> {:error, error}
      wasm -> {:ok, wasm}
    end
  end
end
