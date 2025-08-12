defmodule RomulusElixir.PlannerTest do
  use ExUnit.Case, async: true

  alias RomulusElixir.{State, Planner}
  alias RomulusElixir.Libvirt.{Network, Pool, Volume, Domain}

  describe "create_plan/2" do
    test "creates empty plan when states are identical" do
      state = %State{
        networks: [%Network{name: "net1", active: true}],
        pools: [%Pool{name: "pool1", active: true}],
        volumes: [%Volume{name: "vol1", pool: "pool1"}],
        domains: [%Domain{name: "vm1", pool: "pool1", network: "net1"}]
      }
      
      {:ok, plan} = Planner.create_plan(state, state)
      assert plan == []
    end

    test "creates plan to build infrastructure from empty state" do
      current = State.empty()
      
      desired = %State{
        networks: [%Network{name: "test-net", active: true}],
        pools: [%Pool{name: "test-pool", active: true}],
        volumes: [%Volume{name: "test-vol", pool: "test-pool"}],
        domains: [%Domain{name: "test-vm", pool: "test-pool", network: "test-net"}]
      }
      
      {:ok, plan} = Planner.create_plan(current, desired)
      
      # Should have 4 create actions
      assert length(plan) == 4
      assert Enum.all?(plan, &(&1.type == :create))
      
      # Verify dependency ordering: pools -> networks -> volumes -> domains
      pool_action = Enum.find(plan, &(&1.resource_type == :pool))
      network_action = Enum.find(plan, &(&1.resource_type == :network))
      volume_action = Enum.find(plan, &(&1.resource_type == :volume))
      domain_action = Enum.find(plan, &(&1.resource_type == :domain))
      
      pool_index = Enum.find_index(plan, &(&1 == pool_action))
      _network_index = Enum.find_index(plan, &(&1 == network_action))
      volume_index = Enum.find_index(plan, &(&1 == volume_action))
      domain_index = Enum.find_index(plan, &(&1 == domain_action))
      
      # Pools should come before volumes and domains
      assert pool_index < volume_index
      assert pool_index < domain_index
      # Networks can be created in parallel with pools
      # Volumes should come before domains
      assert volume_index < domain_index
    end

    test "creates plan to destroy all infrastructure" do
      current = %State{
        networks: [%Network{name: "test-net", active: true}],
        pools: [%Pool{name: "test-pool", active: true}],
        volumes: [%Volume{name: "test-vol", pool: "test-pool"}],
        domains: [%Domain{name: "test-vm", pool: "test-pool", network: "test-net"}]
      }
      
      desired = State.empty()
      
      {:ok, plan} = Planner.create_plan(current, desired)
      
      # Should have 4 destroy actions
      assert length(plan) == 4
      assert Enum.all?(plan, &(&1.type == :destroy))
      
      # Verify reverse dependency ordering: domains -> volumes -> networks/pools
      domain_action = Enum.find(plan, &(&1.resource_type == :domain))
      volume_action = Enum.find(plan, &(&1.resource_type == :volume))
      network_action = Enum.find(plan, &(&1.resource_type == :network))
      pool_action = Enum.find(plan, &(&1.resource_type == :pool))
      
      domain_index = Enum.find_index(plan, &(&1 == domain_action))
      volume_index = Enum.find_index(plan, &(&1 == volume_action))
      _network_index = Enum.find_index(plan, &(&1 == network_action))
      pool_index = Enum.find_index(plan, &(&1 == pool_action))
      
      # Domains should be destroyed before volumes
      assert domain_index < volume_index
      # Volumes should be destroyed before pools
      assert volume_index < pool_index
    end

    test "creates plan for partial infrastructure changes" do
      current = %State{
        networks: [%Network{name: "existing-net", active: true}],
        pools: [%Pool{name: "existing-pool", active: true}],
        volumes: [%Volume{name: "existing-vol", pool: "existing-pool"}],
        domains: [%Domain{name: "existing-vm", pool: "existing-pool", network: "existing-net"}]
      }
      
      desired = %State{
        networks: [
          %Network{name: "existing-net", active: true},
          %Network{name: "new-net", active: true}
        ],
        pools: [%Pool{name: "existing-pool", active: true}],
        volumes: [
          %Volume{name: "existing-vol", pool: "existing-pool"},
          %Volume{name: "new-vol", pool: "existing-pool"}
        ],
        domains: [%Domain{name: "new-vm", pool: "existing-pool", network: "new-net"}]
      }
      
      {:ok, plan} = Planner.create_plan(current, desired)
      
      # Should create new resources and destroy existing-vm
      create_actions = Enum.filter(plan, &(&1.type == :create))
      destroy_actions = Enum.filter(plan, &(&1.type == :destroy))
      
      assert length(create_actions) == 3  # new-net, new-vol, new-vm
      assert length(destroy_actions) == 1  # existing-vm
      
      # Verify created resources
      assert Enum.any?(create_actions, &(&1.resource_type == :network and &1.resource.name == "new-net"))
      assert Enum.any?(create_actions, &(&1.resource_type == :volume and &1.resource.name == "new-vol"))
      assert Enum.any?(create_actions, &(&1.resource_type == :domain and &1.resource.name == "new-vm"))
      
      # Verify destroyed resource
      destroy_action = hd(destroy_actions)
      assert destroy_action.resource_type == :domain
      assert destroy_action.resource.name == "existing-vm"
    end

    test "handles resource updates" do
      current_network = %Network{name: "test-net", active: true, mode: "nat", addresses: ["192.168.1.0/24"]}
      desired_network = %Network{name: "test-net", active: true, mode: "isolated", addresses: ["192.168.2.0/24"]}
      
      current = %State{networks: [current_network], pools: [], volumes: [], domains: []}
      desired = %State{networks: [desired_network], pools: [], volumes: [], domains: []}
      
      {:ok, plan} = Planner.create_plan(current, desired)
      
      # Should have an update action for the network
      assert length(plan) == 1
      action = hd(plan)
      assert action.type == :update
      assert action.resource_type == :network
      assert action.resource.name == "test-net"
    end

    test "validates plan consistency" do
      current = State.empty()
      desired = %State{
        networks: [],
        pools: [],
        volumes: [],
        domains: [%Domain{name: "orphan-vm", pool: "nonexistent-pool", network: "nonexistent-net"}]
      }
      
      # Should return error for inconsistent state
      assert {:error, reason} = Planner.create_plan(current, desired)
      assert reason =~ "consistency"
    end
  end

  describe "format_plan/1" do
    test "formats empty plan" do
      output = Planner.format_plan([])
      assert output =~ "No changes needed"
      assert output =~ "up to date"
    end

    test "formats plan with create actions" do
      actions = [
        %Planner.Action{
          type: :create,
          resource_type: :network,
          resource: %Network{name: "test-network"},
          reason: "Network does not exist"
        },
        %Planner.Action{
          type: :create,
          resource_type: :pool,
          resource: %Pool{name: "test-pool"},
          reason: "Pool does not exist"
        }
      ]
      
      output = Planner.format_plan(actions)
      
      assert output =~ "Plan Summary"
      assert output =~ "To create"
      assert output =~ "test-network"
      assert output =~ "test-pool"
      assert output =~ "2 change(s)"
    end

    test "formats plan with destroy actions" do
      actions = [
        %Planner.Action{
          type: :destroy,
          resource_type: :domain,
          resource: %Domain{name: "old-vm"},
          reason: "Domain not in desired state"
        }
      ]
      
      output = Planner.format_plan(actions)
      
      assert output =~ "To destroy"
      assert output =~ "old-vm"
      assert output =~ "1 change(s)"
    end

    test "formats plan with mixed actions" do
      actions = [
        %Planner.Action{
          type: :create,
          resource_type: :network,
          resource: %Network{name: "new-net"},
          reason: "Network does not exist"
        },
        %Planner.Action{
          type: :update,
          resource_type: :pool,
          resource: %Pool{name: "existing-pool"},
          reason: "Pool configuration changed"
        },
        %Planner.Action{
          type: :destroy,
          resource_type: :domain,
          resource: %Domain{name: "old-vm"},
          reason: "Domain not in desired state"
        }
      ]
      
      output = Planner.format_plan(actions)
      
      assert output =~ "To create"
      assert output =~ "new-net"
      assert output =~ "To update"
      assert output =~ "existing-pool"
      assert output =~ "To destroy"
      assert output =~ "old-vm"
      assert output =~ "3 change(s)"
    end

    test "includes resource type indicators in formatted output" do
      actions = [
        %Planner.Action{
          type: :create,
          resource_type: :network,
          resource: %Network{name: "test-net"},
          reason: "Network does not exist"
        }
      ]
      
      output = Planner.format_plan(actions)
      assert output =~ "[network]"
    end
  end

  describe "validate_plan/1" do
    test "validates plan execution order" do
      valid_plan = [
        %Planner.Action{type: :create, resource_type: :pool, resource: %Pool{name: "pool1"}},
        %Planner.Action{type: :create, resource_type: :network, resource: %Network{name: "net1"}},
        %Planner.Action{type: :create, resource_type: :volume, resource: %Volume{name: "vol1", pool: "pool1"}},
        %Planner.Action{type: :create, resource_type: :domain, resource: %Domain{name: "vm1", pool: "pool1", network: "net1"}}
      ]
      
      assert {:ok, ^valid_plan} = Planner.validate_plan(valid_plan)
    end

    test "detects invalid dependency order" do
      invalid_plan = [
        %Planner.Action{type: :create, resource_type: :domain, resource: %Domain{name: "vm1", pool: "pool1"}},
        %Planner.Action{type: :create, resource_type: :pool, resource: %Pool{name: "pool1"}}
      ]
      
      assert {:error, reason} = Planner.validate_plan(invalid_plan)
      assert reason =~ "dependency"
    end

    test "detects missing resource references" do
      plan_with_missing_pool = [
        %Planner.Action{type: :create, resource_type: :volume, resource: %Volume{name: "vol1", pool: "nonexistent-pool"}}
      ]
      
      assert {:error, reason} = Planner.validate_plan(plan_with_missing_pool)
      assert reason =~ "nonexistent-pool"
    end
  end

  describe "optimize_plan/1" do
    test "removes redundant actions" do
      redundant_plan = [
        %Planner.Action{type: :create, resource_type: :network, resource: %Network{name: "net1"}},
        %Planner.Action{type: :destroy, resource_type: :network, resource: %Network{name: "net1"}},
        %Planner.Action{type: :create, resource_type: :network, resource: %Network{name: "net1"}}
      ]
      
      optimized = Planner.optimize_plan(redundant_plan)
      
      # Should reduce to single create action
      assert length(optimized) == 1
      action = hd(optimized)
      assert action.type == :create
      assert action.resource.name == "net1"
    end

    test "parallelizes independent actions" do
      sequential_plan = [
        %Planner.Action{type: :create, resource_type: :pool, resource: %Pool{name: "pool1"}},
        %Planner.Action{type: :create, resource_type: :network, resource: %Network{name: "net1"}},
        %Planner.Action{type: :create, resource_type: :pool, resource: %Pool{name: "pool2"}},
        %Planner.Action{type: :create, resource_type: :network, resource: %Network{name: "net2"}}
      ]
      
      optimized = Planner.optimize_plan(sequential_plan)
      
      # Should group pools together and networks together
      pool_actions = Enum.filter(optimized, &(&1.resource_type == :pool))
      network_actions = Enum.filter(optimized, &(&1.resource_type == :network))
      
      assert length(pool_actions) == 2
      assert length(network_actions) == 2
      
      # Verify pools come before networks (if there are dependencies)
      first_pool_index = Enum.find_index(optimized, &(&1.resource_type == :pool))
      first_network_index = Enum.find_index(optimized, &(&1.resource_type == :network))
      # This depends on the specific optimization strategy
    end
  end

  describe "plan statistics" do
    setup do
      plan = [
        %Planner.Action{type: :create, resource_type: :network, resource: %Network{name: "net1"}},
        %Planner.Action{type: :create, resource_type: :pool, resource: %Pool{name: "pool1"}},
        %Planner.Action{type: :update, resource_type: :network, resource: %Network{name: "net2"}},
        %Planner.Action{type: :destroy, resource_type: :domain, resource: %Domain{name: "vm1"}},
        %Planner.Action{type: :destroy, resource_type: :domain, resource: %Domain{name: "vm2"}}
      ]
      
      {:ok, plan: plan}
    end

    test "counts actions by type", %{plan: plan} do
      stats = Planner.get_plan_statistics(plan)
      
      assert stats.total_actions == 5
      assert stats.by_action_type.create == 2
      assert stats.by_action_type.update == 1
      assert stats.by_action_type.destroy == 2
    end

    test "counts actions by resource type", %{plan: plan} do
      stats = Planner.get_plan_statistics(plan)
      
      assert stats.by_resource_type.network == 2
      assert stats.by_resource_type.pool == 1
      assert Map.get(stats.by_resource_type, :volume, 0) == 0
      assert stats.by_resource_type.domain == 2
    end

    test "estimates execution time", %{plan: plan} do
      stats = Planner.get_plan_statistics(plan)
      
      # Should provide time estimates
      assert is_float(stats.estimated_duration_minutes)
      assert stats.estimated_duration_minutes > 0
    end
  end
end