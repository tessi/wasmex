defmodule Wasmex do
  @moduledoc """
  Documentation for Wasmex.
  """

  @doc """
  Hello world.

  ## Examples

      iex> Wasmex.hello()
      :world

  """
  def hello do
    :world
  end

  use Rustler, otp_app: :wasmex, crate: "wasmex"

  # When your NIF is loaded, it will override this function.
  def add(_a, _b), do: :erlang.nif_error(:nif_not_loaded)
end
