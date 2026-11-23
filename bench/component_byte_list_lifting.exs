# From a Wasmex checkout, build the local NIF with WASMEX_BUILD=1 mix compile.
# Run each sample in a fresh VM, with the operation and size in MiB:
#   elixir -pa '_build/dev/lib/*/ebin' bench/component_byte_list_lifting.exs read 1
#   elixir -pa '_build/dev/lib/*/ebin' bench/component_byte_list_lifting.exs read-result 8
#   elixir -pa '_build/dev/lib/*/ebin' bench/component_byte_list_lifting.exs call-consume 8
# On macOS, prepend /usr/bin/time -l to capture peak RSS.

alias Wasmex.Components

[operation, mib] = System.argv()
{mib, ""} = Integer.parse(mib)
true = mib in 1..8
size = mib * 1024 * 1024

{:ok, _} = Application.ensure_all_started(:wasmex)

wat_path =
  Path.join(__DIR__, "../test/component_fixtures/component_byte_list_lifting.wat")

{:ok, bytes} = wat_path |> File.read!() |> Wasmex.Wat.to_wasm()

check_bytes = fn binary ->
  ^size = byte_size(binary)
  {171, 171} = {:binary.at(binary, 0), :binary.at(binary, size - 1)}
  size
end

{:ok, pid} =
  Components.start_link(
    bytes: bytes,
    binary_byte_lists: true,
    imports: %{"consume" => {:fn, check_bytes}, "notify" => {:fn, fn _ -> :ok end}}
  )

args = if operation == "read-result", do: [size, "label"], else: [size]
{microseconds, result} = :timer.tc(Components, :call_function, [pid, operation, args])

case {operation, result} do
  {"read", {:ok, binary}} -> ^size = check_bytes.(binary)
  {"read-result", {:ok, {:ok, binary}}} -> ^size = check_bytes.(binary)
  {"call-consume", {:ok, ^size}} -> :ok
  {_, {:error, reason}} -> raise reason
end

IO.puts("#{operation} #{mib} MiB #{microseconds} µs")
