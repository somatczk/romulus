defmodule RomulusElixir.ExecutorTest do
  use ExUnit.Case, async: false  # Executor tests might interact with external systems

  alias RomulusElixir.{Executor, Planner, State}
  alias RomulusElixir.Libvirt.{Network, Pool, Volume, Domain}

  describe "execute/1" do
    test "executes empty plan successfully" do
      empty_plan = []
      
      assert {:ok, :success} = Executor.execute(empty_plan)
    end

    test "executes create actions for networks" do
      plan = [
        %Planner.Action{
          type: :create,
          resource_type: :network,
          resource: %Network{
            name: "test-network-#{:rand.uniform(10000)}",
            mode: "nat",
            addresses: ["192.168.100.0/24"],
            dhcp: true,
            dns: true
          },
          reason: "Network does not exist"
        }
      ]

      # Mock the libvirt calls
      with_libvirt_mock([
        create_network: {:ok, :created}
      ]) do
        assert {:ok, :success} = Executor.execute(plan)
      end
    end

    test "executes destroy actions for networks" do
      plan = [
        %Planner.Action{
          type: :destroy,
          resource_type: :network,
          resource: %Network{name: "test-network"},
          reason: "Network not in desired state"
        }
      ]

      with_libvirt_mock([
        delete_network: :ok
      ]) do
        assert {:ok, :success} = Executor.execute(plan)
      end
    end

    test "executes complex plan with multiple resource types" do
      plan = [
        %Planner.Action{
          type: :create,
          resource_type: :pool,
          resource: %Pool{
            name: "test-pool-#{:rand.uniform(10000)}",
            type: "dir",
            path: "/tmp/test-pool"
          }
        },
        %Planner.Action{
          type: :create,
          resource_type: :network,
          resource: %Network{
            name: "test-network-#{:rand.uniform(10000)}",
            mode: "nat",
            addresses: ["192.168.101.0/24"]
          }
        },
        %Planner.Action{
          type: :create,
          resource_type: :volume,
          resource: %Volume{
            name: "test-volume-#{:rand.uniform(10000)}",
            pool: "test-pool",
            format: "qcow2",
            size: "1G"
          }
        }
      ]

      with_libvirt_mock([
        create_pool: {:ok, :created},
        create_network: {:ok, :created},
        create_volume: :ok
      ]) do
        assert {:ok, :success} = Executor.execute(plan)
      end
    end

    test "handles action execution failures" do
      plan = [
        %Planner.Action{
          type: :create,
          resource_type: :network,
          resource: %Network{name: "test-network"},
          reason: "Network does not exist"
        }
      ]

      with_libvirt_mock([
        create_network: {:error, "Network already exists"}
      ]) do
        assert {:error, reason} = Executor.execute(plan)
        assert reason =~ "Network already exists"
      end
    end

    test "stops execution on first failure in serial mode" do
      plan = [
        %Planner.Action{
          type: :create,
          resource_type: :pool,
          resource: %Pool{name: "test-pool1", type: "dir", path: "/tmp/test1"}
        },
        %Planner.Action{
          type: :create,
          resource_type: :pool,
          resource: %Pool{name: "test-pool2", type: "dir", path: "/tmp/test2"}
        }
      ]

      with_libvirt_mock([
        create_pool: fn
          %Pool{name: "test-pool1"} -> {:ok, :created}
          %Pool{name: "test-pool2"} -> {:error, "Failed to create pool"}
        end
      ]) do
        assert {:error, reason} = Executor.execute(plan)
        assert reason =~ "Failed to create pool"
      end
    end

    test "executes cloud-init generation for domains" do
      plan = [
        %Planner.Action{
          type: :create,
          resource_type: :domain,
          resource: %Domain{
            name: "test-vm",
            memory: 1024,
            vcpu: 1,
            pool: "test-pool",
            network: "test-network"
          }
        }
      ]

      with_libvirt_mock([
        create_domain: {:ok, :created}
      ]) do
        with_cloudinit_mock([
          generate_node_cloudinit: {:ok, %{user_data: "user-data", network_config: "network-config"}}
        ]) do
          assert {:ok, :success} = Executor.execute(plan)
        end
      end
    end
  end

  describe "execute/2 with options" do
    test "executes in parallel mode" do
      plan = [
        %Planner.Action{
          type: :create,
          resource_type: :pool,
          resource: %Pool{name: "pool1", type: "dir", path: "/tmp/pool1"}
        },
        %Planner.Action{
          type: :create,
          resource_type: :pool,
          resource: %Pool{name: "pool2", type: "dir", path: "/tmp/pool2"}
        }
      ]

      with_libvirt_mock([
        create_pool: {:ok, :created}
      ]) do
        assert {:ok, :success} = Executor.execute(plan, mode: :parallel)
      end
    end

    test "executes in dry-run mode" do
      plan = [
        %Planner.Action{
          type: :create,
          resource_type: :network,
          resource: %Network{name: "test-network"}
        }
      ]

      # In dry-run mode, no actual libvirt calls should be made
      assert {:ok, :dry_run_complete} = Executor.execute(plan, dry_run: true)
    end

    test "continues on error in continue mode" do
      plan = [
        %Planner.Action{
          type: :create,
          resource_type: :pool,
          resource: %Pool{name: "pool1", type: "dir", path: "/tmp/pool1"}
        },
        %Planner.Action{
          type: :create,
          resource_type: :pool,
          resource: %Pool{name: "pool2", type: "dir", path: "/tmp/pool2"}
        }
      ]

      with_libvirt_mock([
        create_pool: fn
          %Pool{name: "pool1"} -> {:error, "Failed to create"}
          %Pool{name: "pool2"} -> {:ok, :created}
        end
      ]) do
        assert {:ok, :partial_success} = Executor.execute(plan, on_error: :continue)
      end
    end
  end

  describe "validate_plan_before_execution/1" do
    test "validates plan structure before execution" do
      valid_plan = [
        %Planner.Action{
          type: :create,
          resource_type: :network,
          resource: %Network{name: "test-network"},
          reason: "Network does not exist"
        }
      ]

      assert {:ok, ^valid_plan} = Executor.validate_plan_before_execution(valid_plan)
    end

    test "rejects invalid action types" do
      invalid_plan = [
        %Planner.Action{
          type: :invalid_action,
          resource_type: :network,
          resource: %Network{name: "test-network"}
        }
      ]

      assert {:error, reason} = Executor.validate_plan_before_execution(invalid_plan)
      assert reason =~ "invalid action type"
    end

    test "rejects actions with missing resources" do
      invalid_plan = [
        %Planner.Action{
          type: :create,
          resource_type: :network,
          resource: nil
        }
      ]

      assert {:error, reason} = Executor.validate_plan_before_execution(invalid_plan)
      assert reason =~ "missing resource"
    end
  end

  describe "get_execution_summary/1" do
    test "provides execution summary after completion" do
      plan = [
        %Planner.Action{type: :create, resource_type: :network, resource: %Network{name: "net1"}},
        %Planner.Action{type: :create, resource_type: :pool, resource: %Pool{name: "pool1"}},
        %Planner.Action{type: :destroy, resource_type: :domain, resource: %Domain{name: "vm1"}}
      ]

      with_libvirt_mock([
        create_network: {:ok, :created},
        create_pool: {:ok, :created},
        delete_domain: :ok
      ]) do
        {:ok, :success} = Executor.execute(plan)
        summary = Executor.get_execution_summary()

        assert summary.total_actions == 3
        assert summary.successful_actions == 3
        assert summary.failed_actions == 0
        assert summary.execution_time_ms > 0
      end
    end
  end

  describe "rollback functionality" do
    test "can rollback failed execution" do
      plan = [
        %Planner.Action{
          type: :create,
          resource_type: :network,
          resource: %Network{name: "test-network"}
        },
        %Planner.Action{
          type: :create,
          resource_type: :pool,
          resource: %Pool{name: "test-pool", type: "dir", path: "/tmp/test"}
        }
      ]

      with_libvirt_mock([
        create_network: {:ok, :created},
        create_pool: {:error, "Failed to create pool"},
        delete_network: :ok
      ]) do
        assert {:error, _reason} = Executor.execute(plan, rollback_on_error: true)
        
        # Verify rollback was attempted
        summary = Executor.get_execution_summary()
        assert summary.rollback_attempted == true
      end
    end
  end

  describe "resource creation order" do
    test "respects dependency order during execution" do
      plan = [
        %Planner.Action{type: :create, resource_type: :pool, resource: %Pool{name: "pool1"}},
        %Planner.Action{type: :create, resource_type: :network, resource: %Network{name: "net1"}},
        %Planner.Action{type: :create, resource_type: :volume, resource: %Volume{name: "vol1", pool: "pool1"}},
        %Planner.Action{type: :create, resource_type: :domain, resource: %Domain{name: "vm1", pool: "pool1", network: "net1"}}
      ]

      execution_order = []

      with_libvirt_mock([
        create_pool: fn _ -> 
          execution_order = [:pool | execution_order]
          {:ok, :created} 
        end,
        create_network: fn _ -> 
          execution_order = [:network | execution_order]
          {:ok, :created} 
        end,
        create_volume: fn _ -> 
          execution_order = [:volume | execution_order]
          :ok 
        end,
        create_domain: fn _ -> 
          execution_order = [:domain | execution_order]
          {:ok, :created} 
        end
      ]) do
        {:ok, :success} = Executor.execute(plan)
        
        # Verify pools and networks are created before volumes and domains
        execution_order = Enum.reverse(execution_order)
        pool_index = Enum.find_index(execution_order, &(&1 == :pool))
        volume_index = Enum.find_index(execution_order, &(&1 == :volume))
        domain_index = Enum.find_index(execution_order, &(&1 == :domain))
        
        assert pool_index < volume_index
        assert volume_index < domain_index
      end
    end
  end

  # Test helpers and mocks
  defp with_libvirt_mock(mock_functions, test_fun) do
    # Simple mock for libvirt functions
    # In a real implementation, you'd use Mox or similar
    original_adapter = Application.get_env(:romulus_elixir, :libvirt_adapter)
    
    try do
      # Set mock adapter
      Application.put_env(:romulus_elixir, :libvirt_adapter, MockLibvirtAdapter)
      
      # Configure mock responses
      Enum.each(mock_functions, fn {function, response} ->
        :ets.insert(:libvirt_mock, {function, response})
      end)
      
      test_fun.()
    after
      # Restore original adapter
      Application.put_env(:romulus_elixir, :libvirt_adapter, original_adapter)
      :ets.delete_all_objects(:libvirt_mock)
    end
  end

  defp with_cloudinit_mock(mock_functions, test_fun) do
    # Mock cloud-init functions
    Enum.each(mock_functions, fn {function, response} ->
      :ets.insert(:cloudinit_mock, {function, response})
    end)
    
    test_fun.()
  after
    :ets.delete_all_objects(:cloudinit_mock)
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
  end

  setup do
    # Create ETS tables for mocking
    :ets.new(:libvirt_mock, [:named_table, :public])
    :ets.new(:cloudinit_mock, [:named_table, :public])
    
    on_exit(fn ->
      :ets.delete(:libvirt_mock)
      :ets.delete(:cloudinit_mock)
    end)
    
    :ok
  end
end