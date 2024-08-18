defmodule Wasmex.EngineConfigTest do
  use ExUnit.Case, async: true
  import TestHelper, only: [t: 1]
  alias Wasmex.EngineConfig

  doctest EngineConfig

  describe t(&EngineConfig.consume_fuel/1) do
    test "sets the consume_fuel option" do
      config = %EngineConfig{}
      assert %{consume_fuel: false} = EngineConfig.consume_fuel(config, false)
      assert %{consume_fuel: true} = EngineConfig.consume_fuel(config, true)
    end
  end

  describe t(&EngineConfig.cranelift_opt_level/1) do
    test "sets the cranelift_opt_level option" do
      config = %EngineConfig{}
      assert %{cranelift_opt_level: :none} = EngineConfig.cranelift_opt_level(config, :none)
      assert %{cranelift_opt_level: :speed} = EngineConfig.cranelift_opt_level(config, :speed)

      assert %{cranelift_opt_level: :speed_and_size} =
               EngineConfig.cranelift_opt_level(config, :speed_and_size)
    end
  end

  describe t(&EngineConfig.wasm_backtrace_details/1) do
    test "sets the wasm_backtrace_details option" do
      config = %EngineConfig{}
      assert %{wasm_backtrace_details: false} = EngineConfig.wasm_backtrace_details(config, false)
      assert %{wasm_backtrace_details: true} = EngineConfig.wasm_backtrace_details(config, true)
    end
  end

  describe t(&EngineConfig.memory64/1) do
    test "sets the memory64 option" do
      config = %EngineConfig{}
      assert %{memory64: false} = EngineConfig.memory64(config, false)
      assert %{memory64: true} = EngineConfig.memory64(config, true)
    end
  end
end
