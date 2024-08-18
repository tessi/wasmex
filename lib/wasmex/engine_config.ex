defmodule Wasmex.EngineConfig do
  @moduledoc ~S"""
  Configures a `Wasmex.Engine`.

  ## Options

    * `:consume_fuel` - Whether or not to consume fuel when executing Wasm instructions. This defaults to `false`.
    * `:cranelift_opt_level` - Optimization level for the Cranelift code generator. This defaults to `:none`.
    * `:wasm_backtrace_details` - Whether or not backtraces in traps will parse debug info in the Wasm file to have filename/line number information. This defaults to `false`.

  ## Example

      iex> _config = %Wasmex.EngineConfig{}
      ...>           |> Wasmex.EngineConfig.consume_fuel(true)
      ...>           |> Wasmex.EngineConfig.cranelift_opt_level(:speed)
      ...>           |> Wasmex.EngineConfig.wasm_backtrace_details(false)
  """

  defstruct consume_fuel: false,
            cranelift_opt_level: :none,
            wasm_backtrace_details: false,
            memory64: false

  @type t :: %__MODULE__{
          consume_fuel: boolean(),
          cranelift_opt_level: :none | :speed | :speed_and_size,
          wasm_backtrace_details: boolean(),
          memory64: boolean()
        }

  @doc ~S"""
  Configures whether execution of WebAssembly will "consume fuel" to
  either halt or yield execution as desired.

  This can be used to deterministically prevent infinitely-executing
  WebAssembly code by instrumenting generated code to consume fuel as it
  executes. When fuel runs out a trap is raised.

  Note that a `Wasmex.Store` starts with no fuel, so if you enable this option
  you'll have to be sure to pour some fuel into `Wasmex.Store` before
  executing some code. See `Wasmex.StoreOrCaller.set_fuel/2`.

  ## Example

      iex> config = %Wasmex.EngineConfig{}
      ...>          |> Wasmex.EngineConfig.consume_fuel(true)
      iex> config.consume_fuel
      true
  """
  @spec consume_fuel(t(), boolean()) :: t()
  def consume_fuel(%__MODULE__{} = config, consume_fuel) do
    %__MODULE__{config | consume_fuel: consume_fuel}
  end

  @doc ~S"""
  Configures whether the WebAssembly memory type is 64-bit.

  ## Example

      iex> config = %Wasmex.EngineConfig{}
      ...>          |> Wasmex.EngineConfig.memory64(true)
      iex> config.memory64
      true
  """
  @spec memory64(t(), boolean()) :: t()
  def memory64(%__MODULE__{} = config, memory64) do
    %__MODULE__{config | memory64: memory64}
  end

  @doc """
  Configures the Cranelift code generator optimization level.

  Allows one of the following values:

  * `:none` - No optimizations performed, minimizes compilation time by disabling most optimizations.
  * `:speed` - Generates the fastest possible code, but may take longer.
  * `:speed_and_size` - Similar to `speed`, but also performs transformations aimed at reducing code size.
  """
  @spec cranelift_opt_level(t(), :none | :speed | :speed_and_size) :: t()
  def cranelift_opt_level(%__MODULE__{} = config, cranelift_opt_level)
      when cranelift_opt_level in [:none, :speed, :speed_and_size] do
    %__MODULE__{config | cranelift_opt_level: cranelift_opt_level}
  end

  @doc ~S"""
  Configures whether backtraces in traps will parse debug info in the Wasm
  file to have filename/line number information.

  When enabled this will causes modules to retain debugging information
  found in Wasm binaries. This debug information will be used when a trap
  happens to symbolicate each stack frame and attempt to print a
  filename/line number for each Wasm frame in the stack trace.

  ## Example

      iex> config = %Wasmex.EngineConfig{}
      ...>          |> Wasmex.EngineConfig.wasm_backtrace_details(true)
      iex> config.wasm_backtrace_details
      true
  """
  @spec wasm_backtrace_details(t(), boolean()) :: t()
  def wasm_backtrace_details(%__MODULE__{} = config, wasm_backtrace_details) do
    %__MODULE__{config | wasm_backtrace_details: wasm_backtrace_details}
  end
end
