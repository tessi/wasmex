defmodule Wasmex.Components.FunctionServer do
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  def init(_arg) do
    {:ok, %{}}
  end

  def handle_info(msg, state) do
    IO.inspect(msg, label: "In function server")
    {:noreply, state}
  end
end
