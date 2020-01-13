defmodule Wasmex.Native do
   @moduledoc """
  Containes calls that are implemented in our Rust NIF.
  Functions in this module are not intended to be called directly.
  """

  use Rustler, otp_app: :wasmex

  def instance_new_from_bytes(_bytes), do: error()
  def instance_function_export_exists(_resource, _function_name), do: error()
  def instance_call_exported_function(_resource, _function_name, _params), do: error()
  def memory_from_instance(_resource), do: error()
  def memory_bytes_per_element(_resource, _size, _offset), do: error()
  def memory_length(_resource, _size, _offset), do: error()
  def memory_grow(_resource, _size, _offset, _pages), do: error()
  def memory_get(_resource, _size, _offset, _index), do: error()
  def memory_set(_resource, _size, _offset, _index, _value), do: error()
  def memory_read_binary(_resource, _size, _offset, _index), do: error()
  def memory_write_binary(_resource, _size, _offset, _index, _binary), do: error()
  
  # When the NIF is loaded, it will override functions in this module.
  # Calling error is just to handle the case when the nif could not be loaded.
  defp error, do: :erlang.nif_error(:nif_not_loaded)
end