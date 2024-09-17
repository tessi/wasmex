defmodule TodoList do
  use Rustler, otp_app: :wasmex, mode: :debug, crate: "todo_list", path: "test/support/todo_list"

  # When your NIF is loaded, it will override this function.
  def init(_store, _instance), do: error()
  # def add_todo(serialized_component, todo, todo_list), do: error()

  # def load_component(), do: error()

  def instantiate(_store, _component), do: error()

  defp error, do: :erlang.nif_error(:nif_not_loaded)
end
