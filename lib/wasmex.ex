defmodule Wasmex do
  @moduledoc """
  Wasmex is an Elixir library for executing WebAssembly binaries.

  WASM files can be executed using a WebAssembly `Wasmex.Instance`:

  ```elixir
  {:ok, bytes } = File.read("wasmex_test.wasm")
  {:ok, instance } = Wasmex.Instance.from_bytes(bytes)

  instance
    |> Wasmex.Instance.call_exported_function("sum", [50, -8])
  ```

  Memory can be read/written using `Wasmex.Memory`:

  ```elixir
  offset = 7
  index = 4
  value = 42

  {:ok, memory} = Wasmex.Instance.memory(instance, :uint8, offset)
  Wasmex.Memory.set(memory, index, value)
  IO.puts Wasmex.Memory.get(memory, index) # 42
  ```
  """

end
