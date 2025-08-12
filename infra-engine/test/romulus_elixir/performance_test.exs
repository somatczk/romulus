defmodule RomulusElixir.PerformanceTest do
  @moduledoc """
  Performance and concurrency tests using Benchee.
  
  Tests plan generation and execution performance with different resource counts,
  and includes concurrent execution tests to reveal race conditions.
  
  Performance requirements:
  - Plan generation should not exceed 4x Terraform baseline
  - Must handle 10, 50, and 100 resources efficiently
  - Concurrent executor tasks should not have race conditions
  """
  
  use ExUnit.Case, async: false
  
  alias RomulusElixir.{Planner, Executor, State}
  alias RomulusElixir.Libvirt.{Network, Pool, Volume, Domain}
  alias RomulusElixir.Planner.Action
  
  # Test configuration
  @terraform_baseline_ms 1000  # Baseline Terraform plan time (1 second)
  @performance_threshold_ms @terraform_baseline_ms * 4  # 4x Terraform baseline
  @timeout_ms 30_000  # 30 second timeout for performance tests
  
  # Skip performance tests by default, run with: mix test --include performance
  @moduletag :performance
  
  setup_all do
    # Ensure ETS tables exist for mocking
    :ets.new(:libvirt_mock, [:named_table, :public, :set])
    :ets.new(:performance_results, [:named_table, :public, :set])
    
    on_exit(fn ->
      :ets.delete(:libvirt_mock)
      :ets.delete(:performance_results)
    end)
    
    :ok
  end
  
  describe "plan generation performance benchmarks" do
    @tag timeout: @timeout_ms
    test "benchmarks plan generation with varying resource counts" do
      # Test data sets with 10, 50, and 100 resources
      test_cases = [
        {10, "small infrastructure (10 resources)"},
        {50, "medium infrastructure (50 resources)"},
        {100, "large infrastructure (100 resources)"}
      ]
      
      # Run benchmarks for each test case
      Enum.each(test_cases, fn {resource_count, description} ->
        IO.puts("\n=== Benchmarking #{description} ===")
        
        {current_state, desired_state} = generate_test_states(resource_count)
        
        benchmark_results = Benchee.run(
          %{
            "plan_generation_#{resource_count}" => fn ->
              Planner.create_plan(current_state, desired_state)
            end
          },
          time: 5,
          memory_time: 2,
          formatters: [
            {Benchee.Formatters.Console, 
             extended_statistics: true}
          ],
          print: %{
            benchmarking: false,
            fast_warning: false
          }
        )
        
        # Extract performance metrics
        suite_result = benchmark_results.scenarios
                      |> List.first()
        
        avg_time_ms = suite_result.run_time_data.statistics.average / 1_000_000
        
        # Store results for analysis
        :ets.insert(:performance_results, 
          {"plan_generation_#{resource_count}", avg_time_ms})
        
        # Assert performance requirement
        assert avg_time_ms <= @performance_threshold_ms,
          """
          Plan generation for #{resource_count} resources took #{Float.round(avg_time_ms, 2)}ms,
          which exceeds the 4x Terraform baseline of #{@performance_threshold_ms}ms.
          
          Performance breakdown:
          - Average time: #{Float.round(avg_time_ms, 2)}ms
          - Baseline (1x Terraform): #{@terraform_baseline_ms}ms  
          - Threshold (4x Terraform): #{@performance_threshold_ms}ms
          - Ratio: #{Float.round(avg_time_ms / @terraform_baseline_ms, 2)}x
          """
          
        IO.puts("✅ Plan generation for #{resource_count} resources: " <>
                "#{Float.round(avg_time_ms, 2)}ms " <>
                "(#{Float.round(avg_time_ms / @terraform_baseline_ms, 2)}x baseline)")
      end)
    end
    
    @tag timeout: @timeout_ms
    test "benchmarks plan optimization performance" do
      {_, desired_state} = generate_test_states(50)
      {:ok, actions} = Planner.create_plan(State.empty(), desired_state)
      
      Benchee.run(%{
        "plan_validation" => fn -> Planner.validate_plan(actions) end,
        "plan_optimization" => fn -> Planner.optimize_plan(actions) end,
        "plan_statistics" => fn -> Planner.get_plan_statistics(actions) end
      }, 
      time: 3,
      print: %{benchmarking: false}
      )
    end
  end
  
  describe "execution performance benchmarks" do
    @tag timeout: @timeout_ms
    test "benchmarks execution performance with different modes" do
      {_, desired_state} = generate_test_states(25)
      {:ok, plan} = Planner.create_plan(State.empty(), desired_state)
      
      # Setup mock responses for fast execution
      setup_performance_mocks()
      
      benchmark_results = Benchee.run(%{
        "sequential_execution" => fn -> 
          Executor.execute(plan, mode: :sequential) 
        end,
        "parallel_execution" => fn -> 
          Executor.execute(plan, mode: :parallel) 
        end,
        "dry_run_execution" => fn -> 
          Executor.execute(plan, dry_run: true) 
        end
      }, 
      time: 3,
      memory_time: 1,
      print: %{benchmarking: false, fast_warning: false}
      )
      
      # Verify parallel execution is faster than sequential
      sequential_time = get_benchmark_average_time(benchmark_results, "sequential_execution")
      parallel_time = get_benchmark_average_time(benchmark_results, "parallel_execution")
      
      # Parallel should be at least 20% faster for this workload size
      speedup_threshold = 0.8
      assert parallel_time <= sequential_time * speedup_threshold,
        """
        Parallel execution should be faster than sequential execution.
        Sequential: #{Float.round(sequential_time, 2)}ms
        Parallel: #{Float.round(parallel_time, 2)}ms
        Speedup: #{Float.round(sequential_time / parallel_time, 2)}x
        """
    end
    
    @tag timeout: @timeout_ms  
    test "benchmarks execution scalability" do
      resource_counts = [10, 25, 50]
      
      execution_times = Enum.map(resource_counts, fn count ->
        {_, desired_state} = generate_test_states(count)
        {:ok, plan} = Planner.create_plan(State.empty(), desired_state)
        
        setup_performance_mocks()
        
        result = Benchee.run(%{
          "execution_#{count}" => fn -> Executor.execute(plan, dry_run: true) end
        }, 
        time: 2,
        print: %{benchmarking: false, fast_warning: false}
        )
        
        avg_time = get_benchmark_average_time(result, "execution_#{count}")
        {count, avg_time}
      end)
      
      # Verify execution time scales sub-linearly
      [{count1, time1}, {count2, time2}, {count3, time3}] = execution_times
      
      # Check that doubling resources doesn't more than triple execution time
      scaling_factor_1_2 = time2 / time1 / (count2 / count1)
      scaling_factor_2_3 = time3 / time2 / (count3 / count2)
      
      assert scaling_factor_1_2 <= 1.5, 
        "Execution time should scale sub-linearly: #{count1}→#{count2} scaling factor #{Float.round(scaling_factor_1_2, 2)}"
      
      assert scaling_factor_2_3 <= 1.5,
        "Execution time should scale sub-linearly: #{count2}→#{count3} scaling factor #{Float.round(scaling_factor_2_3, 2)}"
    end
  end
  
  describe "concurrency and race condition tests" do
    @tag timeout: @timeout_ms
    test "spawns multiple concurrent Executor tasks to reveal race conditions" do
      {_, desired_state} = generate_test_states(20)
      {:ok, plan} = Planner.create_plan(State.empty(), desired_state)
      
      setup_concurrent_test_mocks()
      
      # Spawn multiple executor tasks concurrently
      num_tasks = 10
      
      tasks = 1..num_tasks
              |> Enum.map(fn task_id ->
                Task.async(fn ->
                  # Add some randomness to timing to increase chance of race conditions
                  Process.sleep(:rand.uniform(50))
                  
                  result = Executor.execute(plan, dry_run: true)
                  {task_id, result, System.monotonic_time()}
                end)
              end)
      
      # Collect all results
      results = Task.await_many(tasks, @timeout_ms)
      
      # Verify all tasks completed successfully
      failed_tasks = Enum.filter(results, fn {_id, result, _time} ->
        case result do
          {:ok, _} -> false
          {:error, _} -> true
        end
      end)
      
      assert Enum.empty?(failed_tasks), 
        "Concurrent execution failed for tasks: #{inspect(failed_tasks)}"
      
      # Verify no race conditions by checking execution order consistency
      successful_results = Enum.filter(results, fn {_id, result, _time} ->
        match?({:ok, _}, result)
      end)
      
      assert length(successful_results) == num_tasks,
        "Expected #{num_tasks} successful executions, got #{length(successful_results)}"
      
      IO.puts("✅ Successfully executed #{num_tasks} concurrent executor tasks without race conditions")
    end
    
    @tag timeout: @timeout_ms
    test "concurrent plan generation with shared state" do
      num_planners = 8
      resource_count = 30
      
      {current_state, desired_state} = generate_test_states(resource_count)
      
      # Test concurrent plan generation with same inputs
      tasks = 1..num_planners
              |> Enum.map(fn planner_id ->
                Task.async(fn ->
                  Process.sleep(:rand.uniform(20))
                  result = Planner.create_plan(current_state, desired_state)
                  {planner_id, result, System.system_time()}
                end)
              end)
      
      results = Task.await_many(tasks, @timeout_ms)
      
      # Verify all planners produced consistent results
      successful_results = Enum.filter(results, fn {_id, result, _time} ->
        match?({:ok, _}, result)
      end)
      
      assert length(successful_results) == num_planners,
        "Expected #{num_planners} successful plan generations"
      
      # Extract all plans and verify consistency
      plans = Enum.map(successful_results, fn {_id, {:ok, plan}, _time} -> plan end)
      
      first_plan = hd(plans)
      
      # All plans should be identical (same actions, same order)
      inconsistent_plans = Enum.reject(plans, fn plan ->
        plans_equivalent?(first_plan, plan)
      end)
      
      assert Enum.empty?(inconsistent_plans),
        "Concurrent plan generation produced inconsistent results: #{length(inconsistent_plans)} different plans"
      
      IO.puts("✅ Successfully generated #{num_planners} consistent plans concurrently")
    end
    
    @tag timeout: @timeout_ms
    test "mixed concurrent plan generation and execution" do
      resource_count = 15
      {current_state, desired_state} = generate_test_states(resource_count)
      {:ok, plan} = Planner.create_plan(current_state, desired_state)
      
      setup_concurrent_test_mocks()
      
      # Mix of planning and execution tasks
      planning_tasks = 1..5
                      |> Enum.map(fn id ->
                        Task.async(fn ->
                          {:plan, id, Planner.create_plan(current_state, desired_state)}
                        end)
                      end)
      
      execution_tasks = 1..5
                       |> Enum.map(fn id ->
                         Task.async(fn ->
                           Process.sleep(:rand.uniform(30))
                           {:execute, id, Executor.execute(plan, dry_run: true)}
                         end)
                       end)
      
      all_tasks = planning_tasks ++ execution_tasks
      results = Task.await_many(all_tasks, @timeout_ms)
      
      # Separate and verify results
      plan_results = Enum.filter(results, fn {type, _, _} -> type == :plan end)
      exec_results = Enum.filter(results, fn {type, _, _} -> type == :execute end)
      
      assert length(plan_results) == 5, "Expected 5 planning results"
      assert length(exec_results) == 5, "Expected 5 execution results"
      
      # Verify all operations succeeded
      failed_plans = Enum.reject(plan_results, fn {_, _, {:ok, _}} -> true; _ -> false end)
      failed_execs = Enum.reject(exec_results, fn {_, _, {:ok, _}} -> true; _ -> false end)
      
      assert Enum.empty?(failed_plans), "Some planning tasks failed: #{inspect(failed_plans)}"
      assert Enum.empty?(failed_execs), "Some execution tasks failed: #{inspect(failed_execs)}"
      
      IO.puts("✅ Successfully mixed concurrent planning and execution operations")
    end
  end
  
  # Helper functions
  
  defp generate_test_states(resource_count) do
    # Create balanced mix of resources
    pools_count = max(1, div(resource_count, 4))
    networks_count = max(1, div(resource_count, 4))
    volumes_count = div(resource_count, 2)
    domains_count = resource_count - pools_count - networks_count - volumes_count
    
    pools = 1..pools_count
            |> Enum.map(fn i ->
              %Pool{
                name: "test-pool-#{i}",
                type: "dir",
                path: "/tmp/test-pool-#{i}"
              }
            end)
    
    networks = 1..networks_count
               |> Enum.map(fn i ->
                 %Network{
                   name: "test-network-#{i}",
                   mode: "nat",
                   addresses: ["192.168.#{100 + i}.0/24"]
                 }
               end)
    
    volumes = 1..volumes_count
              |> Enum.map(fn i ->
                pool_name = "test-pool-#{rem(i - 1, pools_count) + 1}"
                %Volume{
                  name: "test-volume-#{i}",
                  pool: pool_name,
                  size: "10G",
                  format: "qcow2"
                }
              end)
    
    domains = 1..domains_count
              |> Enum.map(fn i ->
                network_name = "test-network-#{rem(i - 1, networks_count) + 1}"
                %Domain{
                  name: "test-vm-#{i}",
                  memory: 1024,
                  vcpu: 1,
                  network: network_name
                }
              end)
    
    current_state = State.empty()
    
    desired_state = %State{
      pools: pools,
      networks: networks,
      volumes: volumes,
      domains: domains,
      timestamp: DateTime.utc_now()
    }
    
    {current_state, desired_state}
  end
  
  defp setup_performance_mocks do
    # Fast mock responses for performance testing
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
  
  defp setup_concurrent_test_mocks do
    # Mock responses that can handle concurrent access
    mock_responses = [
      {:create_pool, fn _ -> 
        Process.sleep(1)  # Minimal delay to simulate real work
        {:ok, :created} 
      end},
      {:create_network, fn _ -> 
        Process.sleep(1)
        {:ok, :created} 
      end},
      {:create_volume, fn _ -> 
        Process.sleep(1)
        :ok 
      end},
      {:create_domain, fn _ -> 
        Process.sleep(1)
        {:ok, :created} 
      end}
    ]
    
    Enum.each(mock_responses, fn {function, response} ->
      :ets.insert(:libvirt_mock, {function, response})
    end)
  end
  
  defp get_benchmark_average_time(benchmark_results, scenario_name) do
    benchmark_results.scenarios
    |> Map.get(scenario_name)
    |> Map.get(:run_time_data)
    |> Map.get(:statistics)
    |> Map.get(:average)
    |> Kernel./(1_000_000)  # Convert nanoseconds to milliseconds
  end
  
  defp plans_equivalent?(plan1, plan2) do
    # Compare plans by converting to comparable format
    normalize_plan(plan1) == normalize_plan(plan2)
  end
  
  defp normalize_plan(plan) do
    plan
    |> Enum.map(fn action ->
      %{
        type: action.type,
        resource_type: action.resource_type,
        resource_name: extract_resource_name(action.resource)
      }
    end)
    |> Enum.sort()
  end
  
  defp extract_resource_name(resource) do
    case resource do
      %{name: name} when is_binary(name) -> name
      _ -> "unknown"
    end
  end
end
