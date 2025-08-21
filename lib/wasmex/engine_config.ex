defmodule Wasmex.EngineConfig do
  @moduledoc ~S"""
  Configures a `Wasmex.Engine`.

  ## Options

    * `:consume_fuel` - Whether or not to consume fuel when executing Wasm instructions. This defaults to `false`.
    * `:cranelift_opt_level` - Optimization level for the Cranelift code generator. This defaults to `:none`.
    * `:wasm_backtrace_details` - Whether or not backtraces in traps will parse debug info in the Wasm file to have filename/line number information. This defaults to `false`.
    * `:debug_info` - Configures whether DWARF debug information will be emitted during compilation. This defaults to `false`.
    * `:memory64` - Whether or not to use 64-bit memory. This defaults to `false`.
    * `:wasm_component_model` - Whether or not to use the WebAssembly component model. This defaults to `true`.
    * `:epoch_interruption` - Whether or not to enable epoch-based interruption. This defaults to `false`.
    * `:epoch_interval_ms` - The interval in milliseconds at which the epoch counter is incremented. This defaults to `10`.

  ## Example

      iex> _config = %Wasmex.EngineConfig{}
      ...>           |> Wasmex.EngineConfig.consume_fuel(true)
      ...>           |> Wasmex.EngineConfig.cranelift_opt_level(:speed)
      ...>           |> Wasmex.EngineConfig.wasm_backtrace_details(false)
      
      # With epoch interruption
      iex> _config = %Wasmex.EngineConfig{}
      ...>           |> Wasmex.EngineConfig.epoch_interruption(true)
      ...>           |> Wasmex.EngineConfig.epoch_interval_ms(10)
  """

  defstruct consume_fuel: false,
            cranelift_opt_level: :none,
            wasm_backtrace_details: false,
            memory64: false,
            wasm_component_model: true,
            debug_info: false,
            epoch_interruption: false,
            epoch_interval_ms: 10

  @type t :: %__MODULE__{
          consume_fuel: boolean(),
          cranelift_opt_level: :none | :speed | :speed_and_size,
          wasm_backtrace_details: boolean(),
          memory64: boolean(),
          wasm_component_model: boolean(),
          debug_info: boolean(),
          epoch_interruption: boolean(),
          epoch_interval_ms: non_neg_integer()
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

  @doc ~S"""
  Configures whether epoch-based interruption is enabled.

  When enabled, the engine will periodically increment an epoch counter,
  and WebAssembly execution can be interrupted when a store's epoch deadline
  is exceeded. This provides an efficient mechanism for preemptive interruption
  without the overhead of fuel metering.

  ## Example

      iex> config = %Wasmex.EngineConfig{}
      ...>          |> Wasmex.EngineConfig.epoch_interruption(true)
      iex> config.epoch_interruption
      true
  """
  @spec epoch_interruption(t(), boolean()) :: t()
  def epoch_interruption(%__MODULE__{} = config, epoch_interruption) do
    %__MODULE__{config | epoch_interruption: epoch_interruption}
  end

  @doc ~S"""
  Configures the interval in milliseconds at which the epoch counter is incremented.

  This setting only takes effect when `epoch_interruption` is enabled.
  The default value is 10 milliseconds.

  ## Example

      iex> config = %Wasmex.EngineConfig{}
      ...>          |> Wasmex.EngineConfig.epoch_interruption(true)
      ...>          |> Wasmex.EngineConfig.epoch_interval_ms(20)
      iex> config.epoch_interval_ms
      20
  """
  @spec epoch_interval_ms(t(), non_neg_integer()) :: t()
  def epoch_interval_ms(%__MODULE__{} = config, epoch_interval_ms) when is_integer(epoch_interval_ms) and epoch_interval_ms > 0 do
    %__MODULE__{config | epoch_interval_ms: epoch_interval_ms}
  end
end
