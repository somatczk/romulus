defmodule RomulusElixir.LibvirtIntegrationTest do
  use ExUnit.Case, async: false
  
  @moduletag :integration
  @moduletag timeout: 300_000  # 5 minutes
  
  alias RomulusElixir.{Config, State, Planner, Executor, Libvirt}
  
  setup_all do
    # Only run if libvirt is available
    case System.cmd("virsh", ["version"], stderr_to_stdout: true) do
      {_, 0} ->
        :ok
      _ ->
        ExUnit.skip("Libvirt not available")
    end
    
    # Use test configuration
    test_config = %{
      cluster: %{name: "test-cluster", domain: "test.local"},
      network: %{
        name: "test-romulus-net",
        mode: "nat",
        cidr: "192.168.200.0/24",
        dhcp: true,
        dns: true
      },
      storage: %{
        pool_name: "test-romulus-pool",
        pool_path: "/tmp/test-romulus-pool",
        base_image: %{
          name: "test-base",
          # Use a small test image
          url: "https://download.cirros-cloud.net/0.6.2/cirros-0.6.2-x86_64-disk.img",
          format: "qcow2"
        }
      },
      nodes: %{
        masters: %{count: 1, memory: 512, vcpus: 1, disk_size: 1073741824, ip_prefix: "192.168.200.1"},
        workers: %{count: 1, memory: 512, vcpus: 1, disk_size: 1073741824, ip_prefix: "192.168.200.2"}
      },
      ssh: %{
        public_key_path: "/tmp/test_key.pub",
        user: "cirros"
      }
    }
    
    # Create test SSH key
    File.write!("/tmp/test_key.pub", "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDtest test@test")
    
    on_exit(fn ->
      # Cleanup
      cleanup_test_resources()
    end)
    
    {:ok, config: test_config}
  end
  
  describe "Infrastructure Lifecycle" do
    @tag :slow
    test "can create and destroy infrastructure", %{config: config} do
      # Generate desired state
      {:ok, desired} = State.from_config(config)
      {:ok, current} = State.fetch_current()
      
      # Create plan
      {:ok, plan} = Planner.create_plan(current, desired)
      
      # Should have create actions
      assert length(plan) > 0
      assert Enum.all?(plan, & &1.type == :create)
      
      # Execute plan
      {:ok, :success} = Executor.execute(plan)
      
      # Verify resources were created
      {:ok, new_state} = State.fetch_current()
      
      # Check network
      assert Enum.any?(new_state.networks, & &1.name == "test-romulus-net")
      
      # Check pool
      assert Enum.any?(new_state.pools, & &1.name == "test-romulus-pool")
      
      # Plan again should show no changes
      {:ok, second_plan} = Planner.create_plan(new_state, desired)
      assert second_plan == []
      
      # Destroy
      empty = State.empty()
      {:ok, destroy_plan} = Planner.create_plan(new_state, empty)
      assert Enum.all?(destroy_plan, & &1.type == :destroy)
      
      {:ok, :success} = Executor.execute(destroy_plan)
      
      # Verify cleanup
      {:ok, final_state} = State.fetch_current()
      refute Enum.any?(final_state.networks, & &1.name == "test-romulus-net")
      refute Enum.any?(final_state.pools, & &1.name == "test-romulus-pool")
    end
  end
  
  describe "Network Management" do
    test "can create and delete network", %{config: _config} do
      network = %Libvirt.Network{
        name: "test-net-#{:rand.uniform(9999)}",
        mode: "nat",
        domain: "test.local",
        addresses: ["192.168.201.0/24"],
        dhcp: true,
        dns: true
      }
      
      # Create network
      assert {:ok, _} = Libvirt.create_network(network)
      
      # Verify it exists
      {:ok, networks} = Libvirt.list_networks()
      assert Enum.any?(networks, & &1.name == network.name)
      
      # Delete network
      assert :ok = Libvirt.delete_network(network.name)
      
      # Verify it's gone
      {:ok, networks} = Libvirt.list_networks()
      refute Enum.any?(networks, & &1.name == network.name)
    end
  end
  
  describe "Storage Management" do
    test "can create and delete pool", %{config: _config} do
      pool = %Libvirt.Pool{
        name: "test-pool-#{:rand.uniform(9999)}",
        type: "dir",
        path: "/tmp/test-pool-#{:rand.uniform(9999)}"
      }
      
      # Create pool
      assert {:ok, _} = Libvirt.create_pool(pool)
      
      # Verify it exists
      {:ok, pools} = Libvirt.list_pools()
      assert Enum.any?(pools, & &1.name == pool.name)
      
      # Delete pool
      assert :ok = Libvirt.delete_pool(pool.name)
      
      # Verify it's gone
      {:ok, pools} = Libvirt.list_pools()
      refute Enum.any?(pools, & &1.name == pool.name)
      
      # Cleanup directory
      File.rm_rf!(pool.path)
    end
  end
  
  describe "Idempotency" do
    test "applying same plan twice has no effect", %{config: config} do
      # Create minimal test config
      mini_config = put_in(config, [:nodes, :masters, :count], 0)
      mini_config = put_in(mini_config, [:nodes, :workers, :count], 0)
      
      {:ok, desired} = State.from_config(mini_config)
      {:ok, current} = State.fetch_current()
      
      # First apply
      {:ok, plan1} = Planner.create_plan(current, desired)
      if length(plan1) > 0 do
        {:ok, :success} = Executor.execute(plan1)
      end
      
      # Second apply should be empty
      {:ok, new_current} = State.fetch_current()
      {:ok, plan2} = Planner.create_plan(new_current, desired)
      assert plan2 == []
      
      # Cleanup
      cleanup_test_resources()
    end
  end
  
  defp cleanup_test_resources do
    # Clean up test resources
    with {:ok, networks} <- Libvirt.list_networks() do
      networks
      |> Enum.filter(& String.starts_with?(&1.name, "test-"))
      |> Enum.each(& Libvirt.delete_network(&1.name))
    end
    
    with {:ok, pools} <- Libvirt.list_pools() do
      pools
      |> Enum.filter(& String.starts_with?(&1.name, "test-"))
      |> Enum.each(fn pool ->
        # Delete volumes first
        with {:ok, volumes} <- Libvirt.list_volumes(pool.name) do
          Enum.each(volumes, & Libvirt.delete_volume(&1.name, pool.name))
        end
        Libvirt.delete_pool(pool.name)
      end)
    end
    
    with {:ok, domains} <- Libvirt.list_domains() do
      domains
      |> Enum.filter(& String.starts_with?(&1.name, "test-"))
      |> Enum.each(& Libvirt.delete_domain(&1.name))
    end
    
    # Clean up test directories
    File.rm_rf!("/tmp/test-romulus-pool")
    File.rm_rf!("/tmp/test-pool-*")
  end
end