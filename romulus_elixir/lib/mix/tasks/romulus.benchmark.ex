defmodule Mix.Tasks.Romulus.Benchmark do
  @moduledoc """
  Run performance benchmarks for RomulusElixir.
  
  This task benchmarks plan generation and execution performance
  to ensure compliance with the documented 4x Terraform baseline.
  
  ## Usage
  
      mix romulus.benchmark
      mix romulus.benchmark --resource-counts 10,25,50
      mix romulus.benchmark --terraform-baseline 500
  
  ## Options
  
    * `--resource-counts` - Comma-separated list of resource counts to test (default: 10,50,100)
    * `--terraform-baseline` - Terraform baseline time in milliseconds (default: 1000)
    * `--parallel` - Include parallel execution benchmarks (default: true)
    * `--concurrency` - Include concurrency tests (default: true)
  
  """
  
  use Mix.Task
  
  alias RomulusElixir.{Planner, Executor, State}
  alias RomulusElixir.Libvirt.{Network, Pool, Volume, Domain}
  
  @shortdoc "Run performance benchmarks"
  
  def run(args) do
    {opts, _, _} = OptionParser.parse(args,
      switches: [
        resource_counts: :string,
        terraform_baseline: :integer,
        parallel: :boolean,
        concurrency: :boolean
      ],
      aliases: [r: :resource_counts, t: :terraform_baseline, p: :parallel, c: :concurrency]
    )
    
    # Parse options with defaults
    resource_counts = parse_resource_counts(opts[:resource_counts] || "10,50,100")
    terraform_baseline_ms = opts[:terraform_baseline] || 1000
    include_parallel = opts[:parallel] != false
    include_concurrency = opts[:concurrency] != false
    
    performance_threshold_ms = terraform_baseline_ms * 4
    
    # Start the application
    Application.ensure_all_started(:romulus_elixir)
    
    Mix.shell().info("🚀 RomulusElixir Performance Benchmarks")
    Mix.shell().info("=" |> String.duplicate(50))
    Mix.shell().info("")
    
    Mix.shell().info("📊 Performance Requirements:")
    Mix.shell().info("  • Terraform baseline: #{terraform_baseline_ms}ms")
    Mix.shell().info("  • Romulus threshold (4x): #{performance_threshold_ms}ms")
    Mix.shell().info("  • Testing resource counts: #{Enum.join(resource_counts, ", ")}")
    Mix.shell().info("")
    
    # Run plan generation benchmarks
    plan_results = benchmark_plan_generation(resource_counts, terraform_baseline_ms, performance_threshold_ms)
    
    if include_parallel do
      # Run execution benchmarks
      benchmark_execution_performance()
    end
    
    if include_concurrency do
      # Run concurrency tests
      run_concurrency_tests()
    end
    
    # Summary
    Mix.shell().info("")
    Mix.shell().info("📋 Summary:")
    
    passed_tests = Enum.count(plan_results, fn {_, _, _, passed} -> passed end)
    total_tests = length(plan_results)
    
    if passed_tests == total_tests do
      Mix.shell().info("  ✅ All performance tests PASSED (#{passed_tests}/#{total_tests})")
      Mix.shell().info("  🎯 Plan generation meets 4x Terraform baseline requirement")
    else
      Mix.shell().info("  ❌ Some performance tests FAILED (#{passed_tests}/#{total_tests})")
      Mix.shell().info("  🚨 Plan generation exceeds 4x Terraform baseline")
      
      failed_tests = Enum.filter(plan_results, fn {_, _, _, passed} -> not passed end)
      Enum.each(failed_tests, fn {count, time_ms, ratio, _} ->
        Mix.shell().info("    - #{count} resources: #{Float.round(time_ms, 2)}ms (#{Float.round(ratio, 2)}x)")
      end)
    end
    
    # Performance trends
    if length(plan_results) >= 2 do
      [{_, time1, _, _}, {_, time2, _, _} | _] = plan_results
      scale_factor = Enum.at(resource_counts, 1) / Enum.at(resource_counts, 0)
      scaling_factor = (time2 / time1) / scale_factor
      
      Mix.shell().info("  📈 Scaling factor: #{Float.round(scaling_factor, 2)}x")
      
      if scaling_factor <= 1.5 do
        Mix.shell().info("  ✅ Good sub-linear scaling performance")
      else
        Mix.shell().info("  ⚠️  Performance may not scale well with large infrastructures")
      end
    end
    
    Mix.shell().info("")
    Mix.shell().info("🔚 Benchmark Complete")
    
    # Exit with appropriate code for CI
    if passed_tests < total_tests do
      System.halt(1)
    end
  end
  
  defp parse_resource_counts(counts_string) do
    counts_string
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.to_integer/1)
  end
  
  defp benchmark_plan_generation(resource_counts, terraform_baseline_ms, performance_threshold_ms) do
    Mix.shell().info("🔧 Plan Generation Performance:")
    
    Enum.map(resource_counts, fn count ->
      Mix.shell().info("  Testing #{count} resources...")
      
      {current_state, desired_state} = generate_test_states(count)
      
      # Measure plan generation time
      {time_us, {:ok, _plan}} = :timer.tc(fn ->
        Planner.create_plan(current_state, desired_state)
      end)
      
      avg_time_ms = time_us / 1000
      ratio = avg_time_ms / terraform_baseline_ms
      passed = avg_time_ms <= performance_threshold_ms
      
      status = if passed, do: "✅ PASS", else: "❌ FAIL"
      
      Mix.shell().info("    #{status} #{count} resources: #{Float.round(avg_time_ms, 2)}ms (#{Float.round(ratio, 2)}x baseline)")
      
      {count, avg_time_ms, ratio, passed}
    end)
  end
  
  defp benchmark_execution_performance do
    Mix.shell().info("")
    Mix.shell().info("⚡ Execution Performance:")
    
    {_, test_state} = generate_test_states(25)
    {:ok, test_plan} = Planner.create_plan(State.empty(), test_state)
    
    # Mock fast responses for consistent benchmarking
    setup_mock_responses()
    
    # Measure sequential execution
    {seq_time_us, _} = :timer.tc(fn ->
      Executor.execute(test_plan, dry_run: true)
    end)
    
    seq_time_ms = seq_time_us / 1000
    
    # Measure parallel execution  
    {par_time_us, _} = :timer.tc(fn ->
      Executor.execute(test_plan, mode: :parallel, dry_run: true)
    end)
    
    par_time_ms = par_time_us / 1000
    
    Mix.shell().info("  Sequential execution: #{Float.round(seq_time_ms, 2)}ms")
    Mix.shell().info("  Parallel execution: #{Float.round(par_time_ms, 2)}ms")
    
    if par_time_ms <= seq_time_ms * 0.9 do
      speedup = seq_time_ms / par_time_ms
      Mix.shell().info("  ✅ Parallel speedup: #{Float.round(speedup, 2)}x")
    else
      Mix.shell().info("  ⚠️  Parallel execution not significantly faster")
    end
  end
  
  defp run_concurrency_tests do
    Mix.shell().info("")
    Mix.shell().info("🔄 Concurrency Tests:")
    
    {_, desired_state} = generate_test_states(20)
    {:ok, plan} = Planner.create_plan(State.empty(), desired_state)
    
    setup_mock_responses()
    
    # Test concurrent execution
    num_tasks = 6
    
    Mix.shell().info("  Running #{num_tasks} concurrent executor tasks...")
    
    tasks = 1..num_tasks
            |> Enum.map(fn task_id ->
              Task.async(fn ->
                # Add some randomness to increase race condition likelihood
                Process.sleep(:rand.uniform(10))
                result = Executor.execute(plan, dry_run: true)
                {task_id, result}
              end)
            end)
    
    results = Task.await_many(tasks, 10_000)
    
    # Verify no race conditions
    failed_tasks = Enum.filter(results, fn {_id, result} ->
      case result do
        {:ok, _} -> false
        _ -> true
      end
    end)
    
    if Enum.empty?(failed_tasks) do
      Mix.shell().info("  ✅ No race conditions detected in concurrent execution")
    else
      Mix.shell().info("  ❌ Race conditions detected: #{inspect(failed_tasks)}")
    end
    
    successful_count = length(results) - length(failed_tasks)
    Mix.shell().info("  Successful tasks: #{successful_count}/#{num_tasks}")
  end
  
  defp generate_test_states(resource_count) do
    # Create balanced distribution of resources
    pools_count = max(1, div(resource_count, 4))
    networks_count = max(1, div(resource_count, 4))
    volumes_count = div(resource_count, 2)
    domains_count = resource_count - pools_count - networks_count - volumes_count
    
    pools = 1..pools_count
            |> Enum.map(fn i ->
              %Pool{
                name: "benchmark-pool-#{i}",
                type: "dir",
                path: "/tmp/benchmark-pool-#{i}"
              }
            end)
    
    networks = 1..networks_count
               |> Enum.map(fn i ->
                 %Network{
                   name: "benchmark-network-#{i}",
                   mode: "nat",
                   addresses: ["192.168.#{100 + i}.0/24"]
                 }
               end)
    
    volumes = 1..volumes_count
              |> Enum.map(fn i ->
                pool_name = "benchmark-pool-#{rem(i - 1, pools_count) + 1}"
                %Volume{
                  name: "benchmark-volume-#{i}",
                  pool: pool_name,
                  size: "10G",
                  format: "qcow2"
                }
              end)
    
    domains = 1..domains_count
              |> Enum.map(fn i ->
                network_name = "benchmark-network-#{rem(i - 1, networks_count) + 1}"
                %Domain{
                  name: "benchmark-vm-#{i}",
                  memory: 1024,
                  vcpu: 1,
                  network: network_name
                }
              end)
    
    current_state = %State{
      pools: [],
      networks: [],
      volumes: [],
      domains: [],
      timestamp: DateTime.utc_now()
    }
    
    desired_state = %State{
      pools: pools,
      networks: networks,
      volumes: volumes,
      domains: domains,
      timestamp: DateTime.utc_now()
    }
    
    {current_state, desired_state}
  end
  
  defp setup_mock_responses do
    # Create ETS table for mocking if needed
    case :ets.info(:libvirt_mock) do
      :undefined -> :ets.new(:libvirt_mock, [:named_table, :public, :set])
      _ -> :ok
    end
    
    # Fast mock responses for benchmarking
    mock_responses = [
      {:create_pool, {:ok, :created}},
      {:create_network, {:ok, :created}},
      {:create_volume, :ok},
      {:create_domain, {:ok, :created}},
      {:delete_pool, :ok},
      {:delete_network, :ok},
      {:delete_volume, :ok},
      {:delete_domain, :ok}
    ]
    
    Enum.each(mock_responses, fn {function, response} ->
      :ets.insert(:libvirt_mock, {function, response})
    end)
  end
end
