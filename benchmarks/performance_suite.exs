#!/usr/bin/env elixir

# Comprehensive performance benchmark suite
# Run on both async and sync branches to compare

# Mix.install([
#   {:benchee, "~> 1.3"},
#   {:wasmex, path: "."}
# ])

# When running inside the project, dependencies are already available
Application.ensure_all_started(:benchee)
Application.ensure_all_started(:wasmex)

defmodule PerformanceSuite do
  @moduledoc """
  Comprehensive benchmark suite for Wasmex runtime performance.
  
  Run this identical benchmark on both branches:
  1. On async-wasmtime branch: mix run benchmarks/performance_suite.exs
  2. On main branch: mix run benchmarks/performance_suite.exs
  
  Then compare the results to see the performance improvements.
  """
  
  def setup do
    wat_source = """
    (module
      (import "env" "sleep_ms" (func $sleep_ms (param i32)))
      (import "env" "compute" (func $compute (param i32) (result i32)))
      
      (memory 1)
      (export "memory" (memory 0))
      
      ;; Pure blocking I/O
      (func $blocking_io (export "blocking_io") (param $ms i32)
        (call $sleep_ms (local.get $ms))
      )
      
      ;; CPU-intensive work
      (func $cpu_work (export "cpu_work") (param $iterations i32) (result i32)
        (local $sum i32)
        (local $i i32)
        
        (local.set $sum (i32.const 0))
        (local.set $i (i32.const 0))
        (loop $loop
          (local.set $sum 
            (i32.add (local.get $sum)
                     (call $compute (local.get $i))))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br_if $loop (i32.lt_u (local.get $i) (local.get $iterations)))
        )
        (local.get $sum)
      )
      
      ;; Mixed workload
      (func $mixed_work (export "mixed_work") (param $compute_iterations i32) (param $sleep_ms i32) (result i32)
        (local $result i32)
        
        ;; Do computation
        (local.set $result (call $cpu_work (local.get $compute_iterations)))
        
        ;; Then block
        (call $sleep_ms (local.get $sleep_ms))
        
        (local.get $result)
      )
    )
    """
    
    {:ok, wasm} = Wasmex.Wat.to_wasm(wat_source)
    
    imports = %{
      "env" => %{
        "sleep_ms" => {:fn, [:i32], [], fn _context, ms -> 
          Process.sleep(ms)
          nil
        end},
        "compute" => {:fn, [:i32], [:i32], fn _context, n ->
          # Simple computation
          Enum.reduce(1..100, 0, fn i, acc -> acc + i * n end)
        end}
      }
    }
    
    %{wasm: wasm, imports: imports}
  end
  
  def run do
    IO.puts("\n#{IO.ANSI.bright()}#{IO.ANSI.magenta()}╔════════════════════════════════════════════════════════════════════════╗#{IO.ANSI.reset()}")
    IO.puts("#{IO.ANSI.bright()}#{IO.ANSI.magenta()}║              Wasmex Performance Benchmark Suite                       ║#{IO.ANSI.reset()}")  
    IO.puts("#{IO.ANSI.bright()}#{IO.ANSI.magenta()}╚════════════════════════════════════════════════════════════════════════╝#{IO.ANSI.reset()}\n")
    
    IO.puts("Branch: #{branch_name()}")
    IO.puts("Cores: #{System.schedulers_online()}")
    IO.puts("Timestamp: #{DateTime.utc_now() |> DateTime.to_string()}\n")
    
    %{wasm: wasm, imports: imports} = setup()
    
    # Run all benchmark scenarios
    benchmark_blocking_io(wasm, imports)
    Process.sleep(500)
    
    benchmark_mixed_workload(wasm, imports)
    Process.sleep(500)
    
    benchmark_scaling(wasm, imports)
    
    print_summary()
  end
  
  defp benchmark_blocking_io(wasm, imports) do
    IO.puts("\n#{IO.ANSI.cyan()}━━━ Test 1: Pure Blocking I/O (50 operations, 100ms each) ━━━#{IO.ANSI.reset()}\n")
    
    Benchee.run(
      %{
        "50 concurrent blocking I/O operations" => fn ->
          tasks = for _ <- 1..50 do
            Task.async(fn ->
              {:ok, store} = Wasmex.Store.new()
              {:ok, pid} = Wasmex.start_link(%{store: store, bytes: wasm, imports: imports})
              {:ok, _} = Wasmex.call_function(pid, :blocking_io, [100])
              Process.exit(pid, :normal)
            end)
          end
          
          Enum.map(tasks, &Task.await(&1, 60000))
        end
      },
      time: 3,
      warmup: 1,
      memory_time: 0,
      formatters: [{Benchee.Formatters.Console, extended_statistics: true}]
    )
  end
  
  defp benchmark_mixed_workload(wasm, imports) do
    IO.puts("\n#{IO.ANSI.cyan()}━━━ Test 2: Mixed CPU + I/O Workload (20 operations) ━━━#{IO.ANSI.reset()}\n")
    
    Benchee.run(
      %{
        "20 mixed workload operations" => fn ->
          tasks = for _ <- 1..20 do
            Task.async(fn ->
              {:ok, store} = Wasmex.Store.new()
              {:ok, pid} = Wasmex.start_link(%{store: store, bytes: wasm, imports: imports})
              {:ok, _} = Wasmex.call_function(pid, :mixed_work, [100, 50])
              Process.exit(pid, :normal)
            end)
          end
          
          Enum.map(tasks, &Task.await(&1, 60000))
        end
      },
      time: 3,
      warmup: 1,
      memory_time: 0,
      formatters: [{Benchee.Formatters.Console, extended_statistics: true}]
    )
  end
  
  defp benchmark_scaling(wasm, imports) do
    IO.puts("\n#{IO.ANSI.cyan()}━━━ Test 3: Scaling Analysis ━━━#{IO.ANSI.reset()}\n")
    
    levels = [1, 10, 25, 50, 100]
    
    IO.puts("Operations | Time (ms) | Throughput (ops/s) | Efficiency")
    IO.puts("-----------|-----------|-------------------|------------")
    
    for ops <- levels do
      start = System.monotonic_time(:millisecond)
      
      tasks = for _ <- 1..ops do
        Task.async(fn ->
          {:ok, store} = Wasmex.Store.new()
          {:ok, pid} = Wasmex.start_link(%{store: store, bytes: wasm, imports: imports})
          {:ok, _} = Wasmex.call_function(pid, :blocking_io, [50])
          Process.exit(pid, :normal)
        end)
      end
      
      Enum.map(tasks, &Task.await(&1, 60000))
      
      elapsed = System.monotonic_time(:millisecond) - start
      throughput = ops / (elapsed / 1000)
      efficiency = (50.0 / elapsed) * 100  # 50ms is theoretical minimum
      
      efficiency_str = if efficiency > 100, do: ">100%", else: "#{Float.round(efficiency, 1)}%"
      
      IO.puts("#{String.pad_leading(Integer.to_string(ops), 10)} | #{String.pad_leading(Integer.to_string(elapsed), 9)} | #{String.pad_leading(Float.to_string(Float.round(throughput, 1)), 17)} | #{efficiency_str}")
    end
  end
  
  defp print_summary do
    IO.puts("\n#{IO.ANSI.bright()}#{IO.ANSI.green()}━━━ Summary ━━━#{IO.ANSI.reset()}\n")
    IO.puts("To compare performance:")
    IO.puts("1. Run this benchmark on the async branch")
    IO.puts("2. Switch to main branch: git checkout main")
    IO.puts("3. Run the same benchmark: mix run benchmarks/performance_suite.exs")
    IO.puts("4. Compare the results\n")
    IO.puts("Expected improvements with async:")
    IO.puts("• Blocking I/O: ~50x faster (100ms vs 5000ms)")
    IO.puts("• Mixed workload: ~10-20x faster")
    IO.puts("• Scaling: Near-linear with operation count")
  end
  
  defp branch_name do
    case System.cmd("git", ["branch", "--show-current"]) do
      {branch, 0} -> String.trim(branch)
      _ -> "unknown"
    end
  end
end

PerformanceSuite.run()