defmodule RomulusElixir.PlannerComprehensiveTest do
  use ExUnit.Case, async: true

  alias RomulusElixir.{Planner, State}
  alias RomulusElixir.Libvirt.{Network, Pool, Volume, Domain}
  alias RomulusElixir.Planner.Action

  describe "create_plan/2" do
    test "creates plan for new infrastructure from scratch" do
      current = State.empty()
      desired = %State{
        networks: [%Network{name: "test-network", mode: "nat"}],
        pools: [%Pool{name: "test-pool", type: "dir", path: "/tmp/pool"}],
        volumes: [%Volume{name: "test-volume", pool: "test-pool"}],
        domains: [%Domain{name: "test-vm", memory: 1024, vcpu: 1}],
        timestamp: DateTime.utc_now()
      }

      assert {:ok, actions} = Planner.create_plan(current, desired)
      
      # Should have 4 create actions
      assert length(actions) == 4
      assert Enum.all?(actions, &(&1.type == :create))
      
      # Check resource types are included
      resource_types = Enum.map(actions, & &1.resource_type)
      assert :pool in resource_types
      assert :network in resource_types  
      assert :volume in resource_types
      assert :domain in resource_types
      
      # Verify actions have resources
      Enum.each(actions, fn action ->
        assert action.resource != nil
        assert is_binary(action.reason)
      end)
    end

    test "creates plan for complete infrastructure destruction" do
      current = %State{
        networks: [%Network{name: "old-network"}],
        pools: [%Pool{name: "old-pool"}],
        volumes: [%Volume{name: "old-volume"}],
        domains: [%Domain{name: "old-vm"}],
        timestamp: DateTime.utc_now()
      }
      desired = State.empty()

      assert {:ok, actions} = Planner.create_plan(current, desired)
      
      # Should have 4 destroy actions
      assert length(actions) == 4
      assert Enum.all?(actions, &(&1.type == :destroy))
      
      # Check all resource types
      resource_types = Enum.map(actions, & &1.resource_type)
      assert :pool in resource_types
      assert :network in resource_types
      assert :volume in resource_types
      assert :domain in resource_types
    end

    test "creates mixed plan for partial changes" do
      current = %State{
        networks: [%Network{name: "keep-network"}, %Network{name: "remove-network"}],
        pools: [%Pool{name: "keep-pool"}],
        volumes: [%Volume{name: "remove-volume"}],
        domains: [],
        timestamp: DateTime.utc_now()
      }
      
      desired = %State{
        networks: [%Network{name: "keep-network"}, %Network{name: "add-network"}],
        pools: [%Pool{name: "keep-pool"}, %Pool{name: "add-pool"}],
        volumes: [%Volume{name: "add-volume"}],
        domains: [%Domain{name: "add-domain"}],
        timestamp: DateTime.utc_now()
      }

      assert {:ok, actions} = Planner.create_plan(current, desired)
      
      # Should have mixed actions
      create_actions = Enum.filter(actions, &(&1.type == :create))
      destroy_actions = Enum.filter(actions, &(&1.type == :destroy))
      
      assert length(create_actions) == 4  # add-network, add-pool, add-volume, add-domain
      assert length(destroy_actions) == 2  # remove-network, remove-volume
      
      # Verify specific actions
      create_names = Enum.map(create_actions, &extract_resource_name(&1.resource))
      destroy_names = Enum.map(destroy_actions, &extract_resource_name(&1.resource))
      
      assert "add-network" in create_names
      assert "add-pool" in create_names
      assert "add-volume" in create_names
      
      assert "remove-volume" in destroy_names
    end

    test "creates empty plan when states are identical" do
      state = %State{
        networks: [%Network{name: "same-network"}],
        pools: [%Pool{name: "same-pool"}],
        volumes: [%Volume{name: "same-volume"}],
        domains: [%Domain{name: "same-domain"}],
        timestamp: DateTime.utc_now()
      }

      assert {:ok, actions} = Planner.create_plan(state, state)
      assert actions == []
    end

    test "handles empty current and desired states" do
      empty1 = State.empty()
      empty2 = State.empty()

      assert {:ok, actions} = Planner.create_plan(empty1, empty2)
      assert actions == []
    end

    test "respects dependency order in created actions" do
      current = State.empty()
      desired = %State{
        # Create all resource types to test ordering
        pools: [%Pool{name: "pool1", type: "dir"}],
        networks: [%Network{name: "net1"}],
        volumes: [%Volume{name: "vol1"}],
        domains: [%Domain{name: "vm1"}],
        timestamp: DateTime.utc_now()
      }

      assert {:ok, actions} = Planner.create_plan(current, desired)
      
      # Find positions of each resource type
      pool_idx = Enum.find_index(actions, &(&1.resource_type == :pool))
      network_idx = Enum.find_index(actions, &(&1.resource_type == :network))
      volume_idx = Enum.find_index(actions, &(&1.resource_type == :volume))
      domain_idx = Enum.find_index(actions, &(&1.resource_type == :domain))
      
      # Verify dependency order: pools -> networks -> volumes -> domains
      assert pool_idx < network_idx
      assert network_idx < volume_idx
      assert volume_idx < domain_idx
    end
  end

  describe "format_plan/1" do
    test "formats empty plan correctly" do
      assert Planner.format_plan([]) == "Infrastructure is up to date. No changes needed."
    end

    test "formats plan with only create actions" do
      actions = [
        %Action{
          type: :create,
          resource_type: :pool,
          resource: %Pool{name: "new-pool"},
          reason: "Pool does not exist"
        },
        %Action{
          type: :create,
          resource_type: :domain,
          resource: %Domain{name: "new-vm"},
          reason: "Domain does not exist"
        }
      ]

      result = Planner.format_plan(actions)
      
      assert result =~ "Plan Summary:"
      assert result =~ "To create:"
      assert result =~ "[pool] pool: new-pool"
      assert result =~ "[domain] domain: new-vm"
      assert result =~ "Total: 2 change(s)"
      refute result =~ "To update:"
      refute result =~ "To destroy:"
    end

    test "formats plan with only destroy actions" do
      actions = [
        %Action{
          type: :destroy,
          resource_type: :network,
          resource: %Network{name: "old-network"},
          reason: "Network not in desired state"
        }
      ]

      result = Planner.format_plan(actions)
      
      assert result =~ "To destroy:"
      assert result =~ "[network] network: old-network"
      assert result =~ "Total: 1 change(s)"
      refute result =~ "To create:"
      refute result =~ "To update:"
    end

    test "formats mixed plan with all action types" do
      actions = [
        %Action{
          type: :create,
          resource_type: :pool,
          resource: %Pool{name: "new-pool"},
          reason: "Pool does not exist"
        },
        %Action{
          type: :update,
          resource_type: :network,
          resource: %Network{name: "update-network"},
          reason: "Network configuration changed"
        },
        %Action{
          type: :destroy,
          resource_type: :volume,
          resource: %Volume{name: "old-volume"},
          reason: "Volume not in desired state"
        }
      ]

      result = Planner.format_plan(actions)
      
      assert result =~ "To create:"
      assert result =~ "To update:"
      assert result =~ "To destroy:"
      assert result =~ "[pool] pool: new-pool"
      assert result =~ "[network] network: update-network"
      assert result =~ "[volume] volume: old-volume"
      assert result =~ "Total: 3 change(s)"
    end

    test "handles resources with unknown names" do
      actions = [
        %Action{
          type: :create,
          resource_type: :unknown,
          resource: %{},  # Resource without name
          reason: "Unknown resource"
        }
      ]

      result = Planner.format_plan(actions)
      
      assert result =~ "[resource] unknown: unknown"
      assert result =~ "Total: 1 change(s)"
    end
  end

  describe "validate_plan/1" do
    test "validates correct plan structure" do
      actions = [
        %Action{
          type: :create,
          resource_type: :pool,
          resource: %Pool{name: "pool1"},
          reason: "Pool does not exist"
        },
        %Action{
          type: :create,
          resource_type: :volume,
          resource: %Volume{name: "vol1", pool: "pool1"},
          reason: "Volume does not exist"
        }
      ]

      assert {:ok, validated_actions} = Planner.validate_plan(actions)
      assert validated_actions == actions
    end

    test "detects invalid dependency order - volumes before pools" do
      actions = [
        %Action{
          type: :create,
          resource_type: :volume,
          resource: %Volume{name: "vol1", pool: "pool1"},
          reason: "Volume does not exist"
        },
        %Action{
          type: :create,
          resource_type: :pool,
          resource: %Pool{name: "pool1"},
          reason: "Pool does not exist"
        }
      ]

      assert {:error, reason} = Planner.validate_plan(actions)
      assert reason =~ "Volumes cannot be created before pools"
    end

    test "detects invalid dependency order - domains before volumes" do
      actions = [
        %Action{
          type: :create,
          resource_type: :domain,
          resource: %Domain{name: "vm1"},
          reason: "Domain does not exist"
        },
        %Action{
          type: :create,
          resource_type: :volume,
          resource: %Volume{name: "vol1", pool: "pool1"},
          reason: "Volume does not exist"
        }
      ]

      assert {:error, reason} = Planner.validate_plan(actions)
      assert reason =~ "Domains cannot be created before volumes"
    end

    test "validates destroy actions don't have dependency constraints" do
      actions = [
        %Action{
          type: :destroy,
          resource_type: :domain,
          resource: %Domain{name: "vm1"},
          reason: "Domain not in desired state"
        },
        %Action{
          type: :destroy,
          resource_type: :pool,
          resource: %Pool{name: "pool1"},
          reason: "Pool not in desired state"
        }
      ]

      # Destroy order doesn't matter for dependency validation
      assert {:ok, _} = Planner.validate_plan(actions)
    end

    test "detects invalid resource references" do
      actions = [
        %Action{
          type: :create,
          resource_type: :volume,
          resource: %Volume{name: "vol1", pool: "nonexistent-pool"},
          reason: "Volume does not exist"
        }
      ]

      assert {:error, reason} = Planner.validate_plan(actions)
      assert reason =~ "Volume 'vol1' references non-existent pool 'nonexistent-pool'"
    end

    test "allows volumes without pool references" do
      actions = [
        %Action{
          type: :create,
          resource_type: :volume,
          resource: %Volume{name: "vol1", pool: nil},
          reason: "Volume does not exist"
        }
      ]

      assert {:ok, _} = Planner.validate_plan(actions)
    end
  end

  describe "optimize_plan/1" do
    test "removes redundant create/destroy pairs" do
      actions = [
        %Action{
          type: :create,
          resource_type: :pool,
          resource: %Pool{name: "pool1"},
          reason: "Pool does not exist"
        },
        %Action{
          type: :destroy,
          resource_type: :pool,
          resource: %Pool{name: "pool1"},
          reason: "Pool not in desired state"
        },
        %Action{
          type: :create,
          resource_type: :network,
          resource: %Network{name: "net1"},
          reason: "Network does not exist"
        }
      ]

      optimized = Planner.optimize_plan(actions)
      
      # The create/destroy pair for pool1 should be removed
      assert length(optimized) == 1
      remaining_action = List.first(optimized)
      assert remaining_action.resource_type == :network
      assert extract_resource_name(remaining_action.resource) == "net1"
    end

    test "removes redundant destroy/create pairs" do
      actions = [
        %Action{
          type: :destroy,
          resource_type: :volume,
          resource: %Volume{name: "vol1"},
          reason: "Volume not in desired state"
        },
        %Action{
          type: :create,
          resource_type: :volume,
          resource: %Volume{name: "vol1"},
          reason: "Volume does not exist"
        }
      ]

      optimized = Planner.optimize_plan(actions)
      
      # The destroy/create pair should be removed
      assert optimized == []
    end

    test "preserves non-redundant actions" do
      actions = [
        %Action{
          type: :create,
          resource_type: :pool,
          resource: %Pool{name: "pool1"},
          reason: "Pool does not exist"
        },
        %Action{
          type: :create,
          resource_type: :pool,
          resource: %Pool{name: "pool2"},
          reason: "Pool does not exist"
        },
        %Action{
          type: :destroy,
          resource_type: :network,
          resource: %Network{name: "net1"},
          reason: "Network not in desired state"
        }
      ]

      optimized = Planner.optimize_plan(actions)
      
      # All actions should be preserved since they're not redundant
      assert length(optimized) == 3
    end

    test "sorts actions by dependency order" do
      actions = [
        %Action{
          type: :create,
          resource_type: :domain,
          resource: %Domain{name: "vm1"},
          reason: "Domain does not exist"
        },
        %Action{
          type: :create,
          resource_type: :pool,
          resource: %Pool{name: "pool1"},
          reason: "Pool does not exist"
        },
        %Action{
          type: :destroy,
          resource_type: :network,
          resource: %Network{name: "net1"},
          reason: "Network not in desired state"
        },
        %Action{
          type: :create,
          resource_type: :volume,
          resource: %Volume{name: "vol1"},
          reason: "Volume does not exist"
        }
      ]

      optimized = Planner.optimize_plan(actions)
      
      # Should be sorted: creates first (pool, network, volume, domain), then destroys
      resource_types = Enum.map(optimized, & &1.resource_type)
      
      create_actions = Enum.filter(optimized, &(&1.type == :create))
      destroy_actions = Enum.filter(optimized, &(&1.type == :destroy))
      
      # Create actions should come before destroy actions
      create_count = length(create_actions)
      assert Enum.take(optimized, create_count) == create_actions
      
      # Check dependency order within creates
      create_types = Enum.map(create_actions, & &1.resource_type)
      pool_idx = Enum.find_index(create_types, &(&1 == :pool))
      volume_idx = Enum.find_index(create_types, &(&1 == :volume))
      domain_idx = Enum.find_index(create_types, &(&1 == :domain))
      
      assert pool_idx < volume_idx
      assert volume_idx < domain_idx
    end
  end

  describe "get_plan_statistics/1" do
    test "calculates statistics for mixed plan" do
      actions = [
        %Action{type: :create, resource_type: :pool, resource: %Pool{name: "pool1"}},
        %Action{type: :create, resource_type: :pool, resource: %Pool{name: "pool2"}},
        %Action{type: :create, resource_type: :network, resource: %Network{name: "net1"}},
        %Action{type: :update, resource_type: :domain, resource: %Domain{name: "vm1"}},
        %Action{type: :destroy, resource_type: :volume, resource: %Volume{name: "vol1"}},
        %Action{type: :destroy, resource_type: :volume, resource: %Volume{name: "vol2"}}
      ]

      stats = Planner.get_plan_statistics(actions)
      
      assert stats.total_actions == 6
      
      # By action type
      assert stats.by_action_type[:create] == 3
      assert stats.by_action_type[:update] == 1
      assert stats.by_action_type[:destroy] == 2
      
      # By resource type
      assert stats.by_resource_type[:pool] == 2
      assert stats.by_resource_type[:network] == 1
      assert stats.by_resource_type[:domain] == 1
      assert stats.by_resource_type[:volume] == 2
      
      # Duration estimate
      assert is_number(stats.estimated_duration_minutes)
      assert stats.estimated_duration_minutes > 0
    end

    test "calculates statistics for empty plan" do
      stats = Planner.get_plan_statistics([])
      
      assert stats.total_actions == 0
      assert stats.by_action_type == %{}
      assert stats.by_resource_type == %{}
      assert stats.estimated_duration_minutes >= 1  # Minimum 1 minute
    end

    test "estimates realistic execution times" do
      # Test with actions that have different duration estimates
      actions = [
        %Action{type: :create, resource_type: :pool, resource: %Pool{name: "pool1"}},     # 1 min
        %Action{type: :create, resource_type: :volume, resource: %Volume{name: "vol1"}}, # 5 min
        %Action{type: :create, resource_type: :domain, resource: %Domain{name: "vm1"}},  # 3 min
        %Action{type: :destroy, resource_type: :network, resource: %Network{name: "net1"}} # 1 min
      ]

      stats = Planner.get_plan_statistics(actions)
      
      # Total should be (1 + 5 + 3 + 1) * 0.6 = 6 minutes (with parallelization factor)
      expected_duration = 10 * 0.6
      assert stats.estimated_duration_minutes == expected_duration
    end
  end

  describe "Action struct" do
    test "requires type, resource_type, and resource fields" do
      # Valid action
      action = %Action{
        type: :create,
        resource_type: :pool,
        resource: %Pool{name: "test-pool"},
        reason: "Pool does not exist"
      }
      
      assert action.type == :create
      assert action.resource_type == :pool
      assert action.resource.name == "test-pool"
      assert action.reason == "Pool does not exist"
    end

    test "enforces required fields" do
      # Valid action should work
      action = %Action{
        type: :create,
        resource_type: :pool,
        resource: %Pool{name: "test"}
      }
      
      assert action.type == :create
      
      # Missing fields will cause compilation errors, not runtime errors
      # This is enforced by the @enforce_keys directive
    end

    test "allows nil reason" do
      action = %Action{
        type: :create,
        resource_type: :pool,
        resource: %Pool{name: "test-pool"}
        # reason is optional
      }
      
      assert action.reason == nil
    end
  end

  # Edge cases and error conditions
  
  describe "edge cases" do
    test "handles resources with nil names" do
      current = State.empty()
      desired = %State{
        pools: [%Pool{name: nil, type: "dir"}],
        networks: [],
        volumes: [],
        domains: [],
        timestamp: DateTime.utc_now()
      }

      assert {:ok, actions} = Planner.create_plan(current, desired)
      # Resources with nil names are filtered out of the name matching,
      # but still result in create actions since they exist in desired
      assert length(actions) == 1
      
      action = List.first(actions)
      assert action.resource.name == nil
      assert action.type == :create
    end

    test "handles duplicate resource names in same type" do
      current = State.empty()
      desired = %State{
        pools: [
          %Pool{name: "duplicate", type: "dir"},
          %Pool{name: "duplicate", type: "dir"}  # Same name
        ],
        networks: [],
        volumes: [],
        domains: [],
        timestamp: DateTime.utc_now()
      }

      assert {:ok, actions} = Planner.create_plan(current, desired)
      
      # Should create actions for both pools (planner doesn't deduplicate)
      pool_actions = Enum.filter(actions, &(&1.resource_type == :pool))
      assert length(pool_actions) == 2
    end

    test "handles very large plans" do
      # Create a large plan with many resources
      many_pools = Enum.map(1..100, fn i -> %Pool{name: "pool-#{i}", type: "dir"} end)
      many_networks = Enum.map(1..100, fn i -> %Network{name: "net-#{i}"} end)
      
      current = State.empty()
      desired = %State{
        pools: many_pools,
        networks: many_networks,
        volumes: [],
        domains: [],
        timestamp: DateTime.utc_now()
      }

      assert {:ok, actions} = Planner.create_plan(current, desired)
      assert length(actions) == 200  # 100 pools + 100 networks
      
      # Verify all are create actions
      assert Enum.all?(actions, &(&1.type == :create))
      
      # Test optimization doesn't crash on large plans
      optimized = Planner.optimize_plan(actions)
      assert length(optimized) == 200
    end
  end

  # Helper functions

  defp extract_resource_name(resource) do
    case resource do
      %{name: name} when is_binary(name) -> name
      _ -> "unknown"
    end
  end
end
