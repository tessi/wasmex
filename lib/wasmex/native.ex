defmodule Wasmex.Native do
   @moduledoc """
  Containes calls that are implemented in our Rust NIF.
  Functions in this module are not intended to be called directly.
  """

  use Rustler, otp_app: :wasmex

  @spec instance_new_from_bytes(binary) :: {:ok, Wasmex.Instance.t} | {:error, atom}
  def instance_new_from_bytes(_bytes), do: error()

  # When the NIF is loaded, it will override functions in this module.
  # Calling error is just to handle the case when the nif could not be loaded.
  defp error, do: :erlang.nif_error(:nif_not_loaded)
end