defmodule RomulusElixir.ExecutorComprehensiveTest do
  use ExUnit.Case, async: false

  alias RomulusElixir.{Executor, Planner}
  alias RomulusElixir.Libvirt.{Network, Pool, Volume, Domain}
  alias RomulusElixir.Planner.Action
  import Mock

  setup do
    # Create ETS table for mocking libvirt calls
    :ets.new(:libvirt_mock, [:named_table, :public, :set])
    :ets.new(:cloudinit_mock, [:named_table, :public, :set])
    
    on_exit(fn ->
      :ets.delete_all_objects(:libvirt_mock)
      :ets.delete_all_objects(:cloudinit_mock)
      :ets.delete(:libvirt_mock)
      :ets.delete(:cloudinit_mock)
    end)
    
    :ok
  end

  describe "execute/1 basic execution" do
    test "executes empty plan successfully" do
      assert {:ok, :success} = Executor.execute([])
    end

    test "executes single create pool action" do
      plan = [
        %Action{
          type: :create,
          resource_type: :pool,
          resource: %Pool{name: "test-pool", type: "dir", path: "/tmp/test"},
          reason: "Pool does not exist"
        }
      ]

      with_libvirt_mock([create_pool: {:ok, :created}]) do
        assert {:ok, :success} = Executor.execute(plan)
      end
    end

    test "executes single create network action" do
      plan = [
        %Action{
          type: :create,
          resource_type: :network,
          resource: %Network{name: "test-network", mode: "nat", addresses: ["192.168.1.0/24"]},
          reason: "Network does not exist"
        }
      ]

      with_libvirt_mock([create_network: {:ok, :created}]) do
        assert {:ok, :success} = Executor.execute(plan)
      end
    end

    test "executes single create volume action" do
      plan = [
        %Action{
          type: :create,
          resource_type: :volume,
          resource: %Volume{name: "test-volume", pool: "test-pool", size: "10G", format: "qcow2"},
          reason: "Volume does not exist"
        }
      ]

      with_libvirt_mock([create_volume: :ok]) do
        assert {:ok, :success} = Executor.execute(plan)
      end
    end

    test "executes single create domain action" do
      plan = [
        %Action{
          type: :create,
          resource_type: :domain,
          resource: %Domain{name: "test-vm", memory: 2048, vcpu: 2, network: "test-net"},
          reason: "Domain does not exist"
        }
      ]

      with_libvirt_mock([create_domain: {:ok, :created}]) do
        assert {:ok, :success} = Executor.execute(plan)
      end
    end

    test "executes destroy actions" do
      plan = [
        %Action{
          type: :destroy,
          resource_type: :domain,
          resource: %Domain{name: "old-vm"},
          reason: "Domain not in desired state"
        },
        %Action{
          type: :destroy,
          resource_type: :volume,
          resource: %Volume{name: "old-volume", pool: "old-pool"},
          reason: "Volume not in desired state"
        },
        %Action{
          type: :destroy,
          resource_type: :network,
          resource: %Network{name: "old-network"},
          reason: "Network not in desired state"
        },
        %Action{
          type: :destroy,
          resource_type: :pool,
          resource: %Pool{name: "old-pool"},
          reason: "Pool not in desired state"
        }
      ]

      with_libvirt_mock([
        delete_domain: :ok,
        delete_volume: :ok,
        delete_network: :ok,
        delete_pool: :ok
      ]) do
        assert {:ok, :success} = Executor.execute(plan)
      end
    end

    test "executes complex multi-resource plan" do
      plan = [
        %Action{
          type: :create,
          resource_type: :pool,
          resource: %Pool{name: "new-pool", type: "dir", path: "/tmp/new-pool"},
          reason: "Pool does not exist"
        },
        %Action{
          type: :create,
          resource_type: :network,
          resource: %Network{name: "new-network", mode: "nat"},
          reason: "Network does not exist"
        },
        %Action{
          type: :create,
          resource_type: :volume,
          resource: %Volume{name: "new-volume", pool: "new-pool", size: "20G"},
          reason: "Volume does not exist"
        },
        %Action{
          type: :destroy,
          resource_type: :domain,
          resource: %Domain{name: "old-vm"},
          reason: "Domain not in desired state"
        }
      ]

      with_libvirt_mock([
        create_pool: {:ok, :created},
        create_network: {:ok, :created},
        create_volume: :ok,
        delete_domain: :ok
      ]) do
        assert {:ok, :success} = Executor.execute(plan)
      end
    end
  end

  describe "execute/1 error handling" do
    test "stops on first error in serial mode" do
      plan = [
        %Action{
          type: :create,
          resource_type: :pool,
          resource: %Pool{name: "pool1", type: "dir"},
          reason: "Pool does not exist"
        },
        %Action{
          type: :create,
          resource_type: :pool,
          resource: %Pool{name: "pool2", type: "dir"},
          reason: "Pool does not exist"
        }
      ]

      with_libvirt_mock([
        create_pool: fn 
          %Pool{name: "pool1"} -> {:ok, :created}
          %Pool{name: "pool2"} -> {:error, "Failed to create pool2"}
        end
      ]) do
        assert {:error, reason} = Executor.execute(plan)
        assert reason =~ "Failed to create pool2"
      end
    end

    test "handles libvirt connection failures" do
      plan = [
        %Action{
          type: :create,
          resource_type: :network,
          resource: %Network{name: "test-network"},
          reason: "Network does not exist"
        }
      ]

      with_libvirt_mock([create_network: {:error, "Connection to libvirt failed"}]) do
        assert {:error, reason} = Executor.execute(plan)
        assert reason =~ "Connection to libvirt failed"
      end
    end

    test "handles resource creation failures with detailed messages" do
      plan = [
        %Action{
          type: :create,
          resource_type: :pool,
          resource: %Pool{name: "bad-pool", type: "dir", path: "/nonexistent/path"},
          reason: "Pool does not exist"
        }
      ]

      with_libvirt_mock([create_pool: {:error, "Directory /nonexistent/path does not exist"}]) do
        assert {:error, reason} = Executor.execute(plan)
        assert reason =~ "Directory /nonexistent/path does not exist"
      end
    end

    test "handles exceptions during action execution" do
      plan = [
        %Action{
          type: :create,
          resource_type: :network,
          resource: %Network{name: "exception-network"},
          reason: "Network does not exist"
        }
      ]

      with_libvirt_mock([
        create_network: fn _network -> raise RuntimeError, "Unexpected error" end
      ]) do
        assert {:error, reason} = Executor.execute(plan)
        assert reason =~ "Unexpected error"
      end
    end

    test "handles missing resource names gracefully" do
      plan = [
        %Action{
          type: :create,
          resource_type: :pool,
          resource: %Pool{name: nil, type: "dir"},  # nil name
          reason: "Pool does not exist"
        }
      ]

      with_libvirt_mock([create_pool: {:ok, :created}]) do
        assert {:ok, :success} = Executor.execute(plan)
      end
    end
  end

  describe "execute/2 with options - execution modes" do
    test "executes in dry-run mode without making actual changes" do
      plan = [
        %Action{
          type: :create,
          resource_type: :pool,
          resource: %Pool{name: "dry-run-pool"},
          reason: "Pool does not exist"
        },
        %Action{
          type: :destroy,
          resource_type: :network,
          resource: %Network{name: "dry-run-network"},
          reason: "Network not in desired state"
        }
      ]

      # In dry-run mode, no libvirt calls should be made
      assert {:ok, :dry_run_complete} = Executor.execute(plan, dry_run: true)
    end

    test "executes in parallel mode" do
      plan = [
        %Action{
          type: :create,
          resource_type: :pool,
          resource: %Pool{name: "pool1", type: "dir"},
          reason: "Pool does not exist"
        },
        %Action{
          type: :create,
          resource_type: :pool,
          resource: %Pool{name: "pool2", type: "dir"},
          reason: "Pool does not exist"
        }
      ]

      with_libvirt_mock([create_pool: {:ok, :created}]) do
        assert {:ok, :success} = Executor.execute(plan, mode: :parallel)
      end
    end

    test "executes in continue-on-error mode" do
      plan = [
        %Action{
          type: :create,
          resource_type: :pool,
          resource: %Pool{name: "good-pool"},
          reason: "Pool does not exist"
        },
        %Action{
          type: :create,
          resource_type: :pool,
          resource: %Pool{name: "bad-pool"},
          reason: "Pool does not exist"
        },
        %Action{
          type: :create,
          resource_type: :network,
          resource: %Network{name: "good-network"},
          reason: "Network does not exist"
        }
      ]

      with_libvirt_mock([
        create_pool: fn
          %Pool{name: "good-pool"} -> {:ok, :created}
          %Pool{name: "bad-pool"} -> {:error, "Pool creation failed"}
        end,
        create_network: {:ok, :created}
      ]) do
        assert {:ok, :partial_success} = Executor.execute(plan, on_error: :continue)
      end
    end

    test "executes with rollback on error" do
      plan = [
        %Action{
          type: :create,
          resource_type: :pool,
          resource: %Pool{name: "pool1"},
          reason: "Pool does not exist"
        },
        %Action{
          type: :create,
          resource_type: :network,
          resource: %Network{name: "failing-network"},
          reason: "Network does not exist"
        }
      ]

      with_libvirt_mock([
        create_pool: {:ok, :created},
        create_network: {:error, "Network creation failed"},
        delete_pool: :ok  # For rollback
      ]) do
        assert {:error, reason} = Executor.execute(plan, rollback_on_error: true)
        assert reason =~ "Network creation failed"
      end
    end
  end

  describe "validate_plan_before_execution/1" do
    test "validates correct plan structure" do
      plan = [
        %Action{
          type: :create,
          resource_type: :pool,
          resource: %Pool{name: "valid-pool"},
          reason: "Pool does not exist"
        }
      ]

      assert {:ok, validated_plan} = Executor.validate_plan_before_execution(plan)
      assert validated_plan == plan
    end

    test "rejects plan with invalid action structure - missing resource" do
      plan = [
        %Action{
          type: :create,
          resource_type: :pool,
          resource: nil,  # Invalid: missing resource
          reason: "Pool does not exist"
        }
      ]

      assert {:error, reason} = Executor.validate_plan_before_execution(plan)
      assert reason =~ "Invalid action structure"
    end

    test "rejects plan with invalid action type" do
      plan = [
        %Action{
          type: :invalid_type,  # Invalid action type
          resource_type: :pool,
          resource: %Pool{name: "test-pool"},
          reason: "Pool does not exist"
        }
      ]

      assert {:error, reason} = Executor.validate_plan_before_execution(plan)
      assert reason =~ "Invalid action structure"
    end

    test "validates empty plan" do
      assert {:ok, []} = Executor.validate_plan_before_execution([])
    end
  end

  describe "get_execution_summary/0" do
    test "returns execution summary structure" do
      summary = Executor.get_execution_summary()
      
      assert is_map(summary)
      assert Map.has_key?(summary, :total_actions)
      assert Map.has_key?(summary, :successful_actions)
      assert Map.has_key?(summary, :failed_actions)
      assert Map.has_key?(summary, :skipped_actions)
      assert Map.has_key?(summary, :execution_time_seconds)
      assert Map.has_key?(summary, :errors)
      
      # Default values
      assert summary.total_actions == 0
      assert summary.successful_actions == 0
      assert summary.failed_actions == 0
      assert summary.skipped_actions == 0
      assert summary.execution_time_seconds == 0
      assert summary.errors == []
    end
  end

  describe "unsupported actions" do
    test "handles update actions by skipping them" do
      plan = [
        %Action{
          type: :update,
          resource_type: :network,
          resource: %Network{name: "update-network"},
          reason: "Network configuration changed"
        }
      ]

      assert {:ok, :success} = Executor.execute(plan)
    end

    test "handles unsupported resource types" do
      plan = [
        %Action{
          type: :create,
          resource_type: :unsupported_type,
          resource: %{name: "unsupported-resource"},
          reason: "Unsupported resource"
        }
      ]

      assert {:ok, :success} = Executor.execute(plan)
    end
  end

  describe "cloud-init integration" do
    test "handles cloud-init volume creation" do
      plan = [
        %Action{
          type: :create,
          resource_type: :cloudinit,
          resource: %{
            vm: %{name: "test-vm", pool: "test-pool"},
            config: %{cluster: %{name: "test"}}
          },
          reason: "Cloud-init ISO needed"
        }
      ]

      with_cloudinit_mock([
        generate_node_cloudinit: {:ok, %{user_data: "user-data", network_config: "network-config"}},
        create_cloudinit_iso: {:ok, "/tmp/test-vm-init.iso"}
      ]).(
        fn -> assert {:ok, :success} = Executor.execute(plan) end
      )
    end

    test "handles cloud-init generation failure" do
      plan = [
        %Action{
          type: :create,
          resource_type: :cloudinit,
          resource: %{
            vm: %{name: "test-vm"},
            config: %{}
          },
          reason: "Cloud-init ISO needed"
        }
      ]

      with_cloudinit_mock([
        generate_node_cloudinit: {:error, "Invalid node configuration"}
      ]).(
        fn -> 
          assert {:error, reason} = Executor.execute(plan)
          assert reason =~ "Invalid node configuration"
        end
      )
    end
  end

  describe "resource extraction and naming" do
    test "extracts resource names from different resource types" do
      plan = [
        %Action{
          type: :create,
          resource_type: :pool,
          resource: %Pool{name: "pool-name"},
          reason: "Pool does not exist"
        },
        %Action{
          type: :create,
          resource_type: :network,
          resource: %Network{name: "network-name"},
          reason: "Network does not exist"
        },
        %Action{
          type: :create,
          resource_type: :volume,
          resource: %Volume{name: "volume-name"},
          reason: "Volume does not exist"
        },
        %Action{
          type: :create,
          resource_type: :domain,
          resource: %Domain{name: "domain-name"},
          reason: "Domain does not exist"
        }
      ]

      with_libvirt_mock([
        create_pool: {:ok, :created},
        create_network: {:ok, :created},
        create_volume: :ok,
        create_domain: {:ok, :created}
      ]) do
        assert {:ok, :success} = Executor.execute(plan)
      end
    end

    test "handles resources without names gracefully" do
      plan = [
        %Action{
          type: :create,
          resource_type: :pool,
          resource: %{type: "dir"},  # No name field
          reason: "Pool does not exist"
        }
      ]

      with_libvirt_mock([create_pool: {:ok, :created}]) do
        assert {:ok, :success} = Executor.execute(plan)
      end
    end
  end

  describe "parallel execution edge cases" do
    test "handles empty dependency groups in parallel mode" do
      plan = []
      
      assert {:ok, :success} = Executor.execute(plan, mode: :parallel)
    end

    test "groups actions by dependency level for parallel execution" do
      plan = [
        %Action{type: :create, resource_type: :domain, resource: %Domain{name: "vm1"}},
        %Action{type: :create, resource_type: :pool, resource: %Pool{name: "pool1"}},
        %Action{type: :create, resource_type: :volume, resource: %Volume{name: "vol1"}},
        %Action{type: :create, resource_type: :network, resource: %Network{name: "net1"}}
      ]

      with_libvirt_mock([
        create_domain: {:ok, :created},
        create_pool: {:ok, :created},
        create_volume: :ok,
        create_network: {:ok, :created}
      ]) do
        assert {:ok, :success} = Executor.execute(plan, mode: :parallel)
      end
    end

    test "handles failure in parallel execution" do
      plan = [
        %Action{type: :create, resource_type: :pool, resource: %Pool{name: "pool1"}},
        %Action{type: :create, resource_type: :pool, resource: %Pool{name: "pool2"}}
      ]

      with_libvirt_mock([
        create_pool: fn
          %Pool{name: "pool1"} -> {:ok, :created}
          %Pool{name: "pool2"} -> {:error, "Pool creation failed"}
        end
      ]) do
        assert {:error, reason} = Executor.execute(plan, mode: :parallel)
        assert reason =~ "Pool creation failed"
      end
    end
  end

  describe "concurrency and race condition detection" do
    @tag timeout: 30_000
    test "detects race conditions in concurrent executor usage" do
      resource_count = 20
      {_, desired_state} = generate_test_states(resource_count)
      {:ok, plan} = RomulusElixir.Planner.create_plan(%RomulusElixir.State{}, desired_state)
      
      # Mock fast responses to increase concurrency pressure
      with_libvirt_mock([
        create_pool: fn _ -> Process.sleep(1); {:ok, :created} end,
        create_network: fn _ -> Process.sleep(1); {:ok, :created} end,
        create_volume: fn _ -> Process.sleep(1); :ok end,
        create_domain: fn _ -> Process.sleep(1); {:ok, :created} end
      ]) do
        # Spawn multiple concurrent executor tasks
        num_tasks = 8
        
        tasks = 1..num_tasks
                |> Enum.map(fn task_id ->
                  Task.async(fn ->
                    # Add randomized timing to increase race condition likelihood
                    Process.sleep(:rand.uniform(20))
                    
                    result = Executor.execute(plan, dry_run: true)
                    {task_id, result, System.monotonic_time()}
                  end)
                end)
        
        # Collect all results
        results = Task.await_many(tasks, 25_000)
        
        # Verify all tasks completed successfully (no race conditions)
        failed_tasks = Enum.filter(results, fn {_id, result, _time} ->
          case result do
            {:ok, _} -> false
            _ -> true
          end
        end)
        
        assert Enum.empty?(failed_tasks), 
          "Race conditions detected in concurrent execution: #{inspect(failed_tasks)}"
        
        successful_count = Enum.count(results, fn {_id, result, _time} ->
          match?({:ok, _}, result)
        end)
        
        assert successful_count == num_tasks,
          "Expected #{num_tasks} successful concurrent executions, got #{successful_count}"
      end
    end
    
    @tag timeout: 30_000  
    test "concurrent planning with shared state produces consistent results" do
      resource_count = 30
      {current_state, desired_state} = generate_test_states(resource_count)
      
      num_planners = 6
      
      # Test concurrent plan generation
      tasks = 1..num_planners
              |> Enum.map(fn planner_id ->
                Task.async(fn ->
                  Process.sleep(:rand.uniform(15))
                  result = RomulusElixir.Planner.create_plan(current_state, desired_state)
                  {planner_id, result, System.system_time()}
                end)
              end)
      
      results = Task.await_many(tasks, 25_000)
      
      # Verify all planners succeeded
      successful_results = Enum.filter(results, fn {_id, result, _time} ->
        match?({:ok, _}, result)
      end)
      
      assert length(successful_results) == num_planners,
        "Expected #{num_planners} successful plan generations"
      
      # Extract all plans and verify consistency
      plans = Enum.map(successful_results, fn {_id, {:ok, plan}, _time} -> plan end)
      
      # All plans should be equivalent (deterministic planning)
      first_plan = hd(plans)
      inconsistent_plans = Enum.reject(plans, fn plan ->
        plans_equivalent?(first_plan, plan)
      end)
      
      assert Enum.empty?(inconsistent_plans),
        "Concurrent planning produced inconsistent results: #{length(inconsistent_plans)} different plans"
    end
  end
  
  describe "rollback functionality" do
    test "rolls back successfully created resources on failure" do
      plan = [
        %Action{type: :create, resource_type: :pool, resource: %Pool{name: "pool1"}},
        %Action{type: :create, resource_type: :network, resource: %Network{name: "net1"}},
        %Action{type: :create, resource_type: :volume, resource: %Volume{name: "vol1"}}
      ]

      with_libvirt_mock([
        create_pool: {:ok, :created},
        create_network: {:ok, :created},
        create_volume: {:error, "Volume creation failed"},
        # Rollback calls
        delete_network: :ok,
        delete_pool: :ok
      ]) do
        assert {:error, reason} = Executor.execute(plan, rollback_on_error: true)
        assert reason =~ "Volume creation failed"
      end
    end

    test "handles rollback failures gracefully" do
      plan = [
        %Action{type: :create, resource_type: :pool, resource: %Pool{name: "pool1"}},
        %Action{type: :create, resource_type: :network, resource: %Network{name: "net1"}}
      ]

      with_libvirt_mock([
        create_pool: {:ok, :created},
        create_network: {:error, "Network creation failed"},
        delete_pool: {:error, "Rollback failed"}  # Rollback also fails
      ]) do
        assert {:error, reason} = Executor.execute(plan, rollback_on_error: true)
        assert reason =~ "Network creation failed"
      end
    end

    test "creates appropriate rollback actions for destroy operations" do
      plan = [
        %Action{type: :destroy, resource_type: :network, resource: %Network{name: "net1"}},
        %Action{type: :destroy, resource_type: :pool, resource: %Pool{name: "pool1"}}
      ]

      with_libvirt_mock([
        delete_network: :ok,
        delete_pool: {:error, "Pool deletion failed"},
        create_network: {:ok, :created}  # Rollback of destroy
      ]) do
        assert {:error, reason} = Executor.execute(plan, rollback_on_error: true)
        assert reason =~ "Pool deletion failed"
      end
    end
  end

  # Helper functions for mocking

  defp with_libvirt_mock(mock_responses, test_fun \\ nil) do
    # Store original libvirt adapter
    original_adapter = Application.get_env(:romulus_elixir, :libvirt_adapter, RomulusElixir.Libvirt)
    
    try do
      # Set mock adapter
      Application.put_env(:romulus_elixir, :libvirt_adapter, MockLibvirtAdapter)
      
      # Store mock responses in ETS
      Enum.each(mock_responses, fn {function, response} ->
        :ets.insert(:libvirt_mock, {function, response})
      end)
      
      if test_fun do
        test_fun.()
      else
        # Return a function that the test can call
        fn test_function ->
          test_function.()
        end
      end
    after
      # Restore original adapter
      Application.put_env(:romulus_elixir, :libvirt_adapter, original_adapter)
      :ets.delete_all_objects(:libvirt_mock)
    end
  end

  defp with_cloudinit_mock(mock_responses) do
    # Store mock responses for cloud-init functions
    Enum.each(mock_responses, fn {function, response} ->
      :ets.insert(:cloudinit_mock, {function, response})
    end)
    
    fn test_function ->
      test_function.()
    end
  end

  # Mock adapter module for testing
  defmodule MockLibvirtAdapter do
    def create_network(network) do
      case :ets.lookup(:libvirt_mock, :create_network) do
        [{_, response}] when is_function(response) -> response.(network)
        [{_, response}] -> response
        [] -> {:ok, :created}
      end
    end

    def create_pool(pool) do
      case :ets.lookup(:libvirt_mock, :create_pool) do
        [{_, response}] when is_function(response) -> response.(pool)
        [{_, response}] -> response
        [] -> {:ok, :created}
      end
    end

    def create_volume(volume) do
      case :ets.lookup(:libvirt_mock, :create_volume) do
        [{_, response}] when is_function(response) -> response.(volume)
        [{_, response}] -> response
        [] -> :ok
      end
    end

    def create_domain(domain) do
      case :ets.lookup(:libvirt_mock, :create_domain) do
        [{_, response}] when is_function(response) -> response.(domain)
        [{_, response}] -> response
        [] -> {:ok, :created}
      end
    end

    def delete_network(name) do
      case :ets.lookup(:libvirt_mock, :delete_network) do
        [{_, response}] when is_function(response) -> response.(name)
        [{_, response}] -> response
        [] -> :ok
      end
    end

    def delete_pool(name) do
      case :ets.lookup(:libvirt_mock, :delete_pool) do
        [{_, response}] when is_function(response) -> response.(name)
        [{_, response}] -> response
        [] -> :ok
      end
    end

    def delete_volume(name, pool) do
      case :ets.lookup(:libvirt_mock, :delete_volume) do
        [{_, response}] when is_function(response) -> response.(name, pool)
        [{_, response}] -> response
        [] -> :ok
      end
    end

    def delete_domain(name) do
      case :ets.lookup(:libvirt_mock, :delete_domain) do
        [{_, response}] when is_function(response) -> response.(name)
        [{_, response}] -> response
        [] -> :ok
      end
    end

    def start_domain(name) do
      case :ets.lookup(:libvirt_mock, :start_domain) do
        [{_, response}] when is_function(response) -> response.(name)
        [{_, response}] -> response
        [] -> :ok
      end
    end

    def stop_domain(name) do
      case :ets.lookup(:libvirt_mock, :stop_domain) do
        [{_, response}] when is_function(response) -> response.(name)
        [{_, response}] -> response
        [] -> :ok
      end
    end

    def get_domain_info(name) do
      case :ets.lookup(:libvirt_mock, :get_domain_info) do
        [{_, response}] when is_function(response) -> response.(name)
        [{_, response}] -> response
        [] -> {:ok, %{}}
      end
    end

    def exists?(type, name) do
      case :ets.lookup(:libvirt_mock, :exists?) do
        [{_, response}] when is_function(response) -> response.(type, name)
        [{_, response}] -> response
      [] -> true
      end
    end
  end
  
  # Helper functions for test data generation and comparison
  
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
    
    current_state = %RomulusElixir.State{
      pools: [],
      networks: [],
      volumes: [],
      domains: []
    }
    
    desired_state = %RomulusElixir.State{
      pools: pools,
      networks: networks,
      volumes: volumes,
      domains: domains
    }
    
    {current_state, desired_state}
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
