# Build the native code with WASMEX_BUILD=1 mix compile.
# Run each case in a fresh VM to compare process high-water marks.
#
# CASE=memory-write SIZE_BYTES=33554432 elixir -pa '_build/dev/lib/*/ebin' bench/binary_transfers.exs
# CASE=pipe-read SIZE_BYTES=33554432 elixir -pa '_build/dev/lib/*/ebin' bench/binary_transfers.exs
#
# Set SAMPLES=1 and WARMUP=0 for single-call peak RSS measurements.
# On macOS wrap the command in /usr/bin/time -l. On Linux use /usr/bin/time -v.

alias Wasmex.{Instance, Memory, Module, Pipe, Store}

{:ok, _applications} = Application.ensure_all_started(:wasmex)

size = System.get_env("SIZE_BYTES", "33554432") |> String.to_integer()
samples = System.get_env("SAMPLES", "21") |> String.to_integer()
warmup = System.get_env("WARMUP", "3") |> String.to_integer()

pattern = <<0, 255, 195, 40, 226, 130, 42, 20>>
payload = binary_part(:binary.copy(pattern, div(size + 7, 8)), 0, size)

{operation, verify} =
  case System.fetch_env!("CASE") do
    "memory-write" ->
      offset = 17
      pages = div(offset + size + 65_535, 65_536)
      {:ok, store} = Store.new()

      {:ok, module} =
        Module.compile(store, ~s[(module (memory (export "memory") #{pages}))])

      {:ok, instance} = Instance.new(store, module, %{})
      {:ok, memory} = Memory.from_instance(store, instance)

      operation = fn ->
        start = System.monotonic_time(:nanosecond)
        :ok = Memory.write_binary(store, memory, offset, payload)
        System.monotonic_time(:nanosecond) - start
      end

      verify = fn ->
        Stream.iterate(0, &(&1 + 65_536))
        |> Enum.take_while(&(&1 < size))
        |> Enum.each(fn start ->
          length = min(65_536, size - start)
          expected = binary_part(payload, start, length)
          ^expected = Memory.read_binary(store, memory, offset + start, length)
        end)
      end

      {operation, verify}

    "pipe-read" ->
      {:ok, pipe} = Pipe.new(max_size: size)
      {:ok, ^size} = Pipe.write(pipe, payload)

      operation = fn ->
        :ok = Pipe.seek(pipe, 0)
        start = System.monotonic_time(:nanosecond)
        result = Pipe.read(pipe)
        elapsed = System.monotonic_time(:nanosecond) - start
        ^payload = result
        <<>> = Pipe.read(pipe)
        elapsed
      end

      {operation, fn -> ^size = Pipe.size(pipe) end}
  end

for _ <- List.duplicate(:warmup, warmup), do: operation.()

timings =
  Enum.map(1..samples, fn _ ->
    :erlang.garbage_collect()
    operation.()
  end)
  |> Enum.sort()

verify.()

median = Enum.at(timings, div(samples, 2)) / 1000
IO.puts("#{System.fetch_env!("CASE")} bytes=#{size} samples=#{samples} median_us=#{median}")
