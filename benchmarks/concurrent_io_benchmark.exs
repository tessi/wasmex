#!/usr/bin/env elixir

# Benchmark for testing concurrent I/O performance
# Run on both async and sync branches to compare performance

Application.ensure_all_started(:wasmex)

defmodule ConcurrentIOBenchmark do
  @moduledoc """
  Benchmark testing concurrent I/O operations.
  Measures how the runtime handles multiple blocking operations.
  
  Run this on both the async branch and main branch to compare:
  - Async branch: Should complete in ~100ms regardless of operation count
  - Sync branch: Should take 100ms * operation_count
  """
  
  def setup do
    wat_source = """
    (module
      (import "env" "sleep_ms" (func $sleep_ms (param i32)))
      
      (func $blocking_io (export "blocking_io") (param $ms i32)
        (call $sleep_ms (local.get $ms))
      )
    )
    """
    
    {:ok, wasm} = Wasmex.Wat.to_wasm(wat_source)
    
    imports = %{
      "env" => %{
        "sleep_ms" => {:fn, [:i32], [], fn _context, ms -> 
          Process.sleep(ms)
          nil
        end}
      }
    }
    
    %{wasm: wasm, imports: imports}
  end
  
  def run_operations(wasm, imports, count, sleep_ms) do
    tasks = for _ <- 1..count do
      Task.async(fn ->
        {:ok, store} = Wasmex.Store.new()
        {:ok, pid} = Wasmex.start_link(%{store: store, bytes: wasm, imports: imports})
        {:ok, _} = Wasmex.call_function(pid, :blocking_io, [sleep_ms])
        Process.exit(pid, :normal)
      end)
    end
    
    Enum.map(tasks, &Task.await(&1, 60000))
  end
  
  def benchmark do
    %{wasm: wasm, imports: imports} = setup()
    
    IO.puts("\n#{IO.ANSI.bright()}#{IO.ANSI.cyan()}════════════════════════════════════════════════════════════════════#{IO.ANSI.reset()}")
    IO.puts("#{IO.ANSI.bright()}             Concurrent I/O Performance Benchmark#{IO.ANSI.reset()}")
    IO.puts("#{IO.ANSI.bright()}#{IO.ANSI.cyan()}════════════════════════════════════════════════════════════════════#{IO.ANSI.reset()}\n")
    
    # Get system info
    core_count = System.schedulers_online()
    IO.puts("System: #{core_count} cores available")
    IO.puts("Runtime: #{runtime_type()}\n")
    
    # Test with different concurrency levels
    test_configs = [
      {10, 100, "Low concurrency"},
      {50, 100, "Medium concurrency"},
      {100, 100, "High concurrency"},
      {200, 50, "Very high concurrency"},
    ]
    
    for {ops, sleep_ms, description} <- test_configs do
      IO.puts("\n#{IO.ANSI.yellow()}Test: #{description}#{IO.ANSI.reset()}")
      IO.puts("Operations: #{ops}, Sleep: #{sleep_ms}ms each")
      
      # Warmup
      run_operations(wasm, imports, 1, 1)
      
      # Measure
      start_time = System.monotonic_time(:millisecond)
      run_operations(wasm, imports, ops, sleep_ms)
      elapsed = System.monotonic_time(:millisecond) - start_time
      
      throughput = ops / (elapsed / 1000)
      theoretical_time = sleep_ms  # All should run in parallel
      efficiency = (theoretical_time / elapsed) * 100
      
      IO.puts("  Time: #{IO.ANSI.bright()}#{elapsed}ms#{IO.ANSI.reset()}")
      IO.puts("  Throughput: #{Float.round(throughput, 1)} ops/sec")
      IO.puts("  Parallel efficiency: #{efficiency_color(efficiency)}#{Float.round(efficiency, 1)}%#{IO.ANSI.reset()}")
    end
    
    IO.puts("\n#{IO.ANSI.bright()}Note:#{IO.ANSI.reset()} Compare these results with the same benchmark on the sync branch.")
    IO.puts("Async should show near 100% efficiency, sync should show ~#{Float.round(100.0/50, 1)}% efficiency.\n")
  end
  
  defp runtime_type do
    # Try to detect if we're running async or sync based on performance characteristics
    # This is a heuristic - the real test is comparing branches
    "Wasmex (measure both branches for comparison)"
  end
  
  defp efficiency_color(efficiency) when efficiency >= 90, do: IO.ANSI.bright() <> IO.ANSI.green()
  defp efficiency_color(efficiency) when efficiency >= 70, do: IO.ANSI.green()
  defp efficiency_color(efficiency) when efficiency >= 50, do: IO.ANSI.yellow()
  defp efficiency_color(_), do: IO.ANSI.red()
end

ConcurrentIOBenchmark.benchmark()