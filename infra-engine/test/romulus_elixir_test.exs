defmodule RomulusElixirTest do
  use ExUnit.Case
  doctest RomulusElixir
  
  alias RomulusElixir.{Config, State, Planner}
  
  describe "Config" do
    test "loads and validates configuration" do
      config_path = "test/fixtures/test_config.yaml"
      File.mkdir_p!("test/fixtures")
      File.write!(config_path, """
      cluster:
        name: test-cluster
        domain: test.local
      network:
        name: test-network
        cidr: "10.0.0.0/24"
      storage:
        pool_name: test-pool
        pool_path: /tmp/test-pool
        base_image:
          name: test-base
          url: http://example.com/image.qcow2
      nodes:
        masters:
          count: 1
          memory: 1024
          vcpus: 1
          disk_size: 10737418240
          ip_prefix: "10.0.0.1"
        workers:
          count: 2
          memory: 2048
          vcpus: 2
          disk_size: 21474836480
          ip_prefix: "10.0.0.2"
      ssh:
        public_key_path: /tmp/test_key.pub
      """)
      
      assert {:ok, config} = Config.load(config_path)
      assert config[:cluster][:name] == "test-cluster"
      assert config[:nodes][:masters][:count] == 1
      assert config[:nodes][:workers][:count] == 2
      
      File.rm!(config_path)
    end
    
    test "rejects invalid configuration" do
      assert {:error, _} = Config.validate([])
      assert {:error, _} = Config.validate([cluster: []])
    end
  end
  
  describe "State" do
    test "creates empty state" do
      state = State.empty()
      assert state.networks == []
      assert state.pools == []
      assert state.volumes == []
      assert state.domains == []
    end
    
    test "generates state from config" do
      config = [
        cluster: [name: "test", domain: "test.local"],
        network: [name: "test-net", mode: "nat", cidr: "10.0.0.0/24", dhcp: true, dns: true],
        storage: [
          pool_name: "test-pool",
          pool_path: "/tmp/test",
          base_image: [name: "base", url: "http://example.com/img.qcow2", format: "qcow2"]
        ],
        nodes: [
          masters: [count: 1, memory: 1024, vcpus: 1, disk_size: 10737418240, ip_prefix: "10.0.0.1"],
          workers: [count: 2, memory: 2048, vcpus: 2, disk_size: 10737418240, ip_prefix: "10.0.0.2"]
        ],
        ssh: [public_key_path: "/tmp/key.pub", user: "test"]
      ]
      
      assert {:ok, state} = State.from_config(config)
      assert length(state.networks) == 1
      assert length(state.pools) == 1
      assert length(state.domains) == 3  # 1 master + 2 workers
      
      # Check volumes: base + 3 VM disks + 3 cloudinit ISOs
      assert length(state.volumes) == 7
    end
  end
  
  describe "Planner" do
    test "creates empty plan for matching states" do
      state = State.empty()
      assert {:ok, plan} = Planner.create_plan(state, state)
      assert plan == []
    end
    
    test "creates plan for new infrastructure" do
      current = State.empty()
      
      config = [
        cluster: [name: "test", domain: "test.local"],
        network: [name: "test-net", mode: "nat", cidr: "10.0.0.0/24", dhcp: true, dns: true],
        storage: [
          pool_name: "test-pool",
          pool_path: "/tmp/test",
          base_image: [name: "base", url: "http://example.com/img.qcow2", format: "qcow2"]
        ],
        nodes: [
          masters: [count: 1, memory: 1024, vcpus: 1, disk_size: 10737418240, ip_prefix: "10.0.0.1"],
          workers: [count: 1, memory: 2048, vcpus: 2, disk_size: 10737418240, ip_prefix: "10.0.0.2"]
        ],
        ssh: [public_key_path: "/tmp/key.pub", user: "test"]
      ]
      
      {:ok, desired} = State.from_config(config)
      {:ok, plan} = Planner.create_plan(current, desired)
      
      # Should have create actions for pool, network, volumes, and domains
      assert length(plan) > 0
      assert Enum.all?(plan, fn action -> action.type == :create end)
    end
    
    test "formats plan for display" do
      plan = [
        %Planner.Action{
          type: :create,
          resource_type: :network,
          resource: %{name: "test-network"},
          reason: "Network does not exist"
        }
      ]
      
      output = Planner.format_plan(plan)
      assert output =~ "test-network"
      assert output =~ "To create"
    end
  end
end