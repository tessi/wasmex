defmodule Wasmex.Native do
  @moduledoc false

  use Rustler, otp_app: :wasmex

  def module_compile(_bytes), do: error()
  def module_name(_module_resource), do: error()
  def module_set_name(_module_resource, _binary), do: error()
  def module_serialize(_module_resource), do: error()
  def module_unsafe_deserialize(_binary), do: error()

  def instance_new(_module_resource, _imports), do: error()
  def instance_new_wasi(_module_resource, _imports, _args, _env, _opts), do: error()
  def instance_function_export_exists(_instance_resource, _function_name), do: error()

  def instance_call_exported_function(_instance_resource, _function_name, _params, _from),
    do: error()

  def namespace_receive_callback_result(_callback_token, _success, _params), do: error()
  def memory_from_instance(_memory_resource), do: error()
  def memory_bytes_per_element(_size), do: error()
  def memory_length(_memory_resource, _size, _offset), do: error()
  def memory_grow(_memory_resource, _pages), do: error()
  def memory_get(_memory_resource, _size, _offset, _index), do: error()
  def memory_set(_memory_resource, _size, _offset, _index, _value), do: error()
  def memory_read_binary(_memory_resource, _size, _offset, _index, _length), do: error()
  def memory_write_binary(_memory_resource, _size, _offset, _index, _binary), do: error()
  def pipe_create(), do: error()
  def pipe_size(_pipe_resource), do: error()
  def pipe_set_len(_pipe_resource, _len), do: error()
  def pipe_read_binary(_pipe_resource), do: error()
  def pipe_write_binary(_pipe_resource, _binary), do: error()

  # When the NIF is loaded, it will override functions in this module.
  # Calling error is handles the case when the nif could not be loaded.
  defp error, do: :erlang.nif_error(:nif_not_loaded)
end
