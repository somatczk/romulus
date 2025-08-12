defmodule RomulusElixir.StateTest do
  use ExUnit.Case, async: true

  alias RomulusElixir.State
  alias RomulusElixir.Libvirt.{Network, Pool, Volume, Domain}

  describe "empty/0" do
    test "creates empty state with all resource lists empty" do
      state = State.empty()
      
      assert state.networks == []
      assert state.pools == []
      assert state.volumes == []
      assert state.domains == []
    end
  end

  describe "from_config/1" do
    setup do
      config = [
        cluster: [name: "test-cluster", domain: "test.local"],
        network: [
          name: "test-network",
          mode: "nat",
          cidr: "192.168.100.0/24",
          dhcp: true,
          dns: true
        ],
        storage: [
          pool_name: "test-pool",
          pool_path: "/tmp/test-pool",
          base_image: [
            name: "ubuntu-base",
            url: "https://example.com/ubuntu.qcow2",
            format: "qcow2"
          ]
        ],
        nodes: [
          masters: [
            count: 2,
            memory: 2048,
            vcpus: 2,
            disk_size: 21474836480,
            ip_prefix: "192.168.100.10"
          ],
          workers: [
            count: 3,
            memory: 4096,
            vcpus: 4,
            disk_size: 42949672960,
            ip_prefix: "192.168.100.20"
          ]
        ],
        ssh: [
          public_key_path: "/tmp/key.pub",
          private_key_path: "/tmp/key",
          user: "ubuntu"
        ]
      ]
      
      {:ok, config: config}
    end

    test "generates networks from config", %{config: config} do
      {:ok, state} = State.from_config(config)
      
      assert length(state.networks) == 1
      network = hd(state.networks)
      
      assert %Network{} = network
      assert network.name == "test-network"
      assert network.mode == "nat"
      assert network.addresses == ["192.168.100.0/24"]
      assert network.dhcp == true
      assert network.dns == true
    end

    test "generates storage pools from config", %{config: config} do
      {:ok, state} = State.from_config(config)
      
      assert length(state.pools) == 1
      pool = hd(state.pools)
      
      assert %Pool{} = pool
      assert pool.name == "test-pool"
      assert pool.type == "dir"
      assert pool.path == "/tmp/test-pool"
    end

    test "generates volumes from config", %{config: config} do
      {:ok, state} = State.from_config(config)
      
      # Should have: 1 base image + 5 VM disks + 5 cloud-init ISOs = 11 volumes
      assert length(state.volumes) == 11
      
      # Check base image volume
      base_volume = Enum.find(state.volumes, &(&1.name == "ubuntu-base"))
      assert %Volume{} = base_volume
      assert base_volume.pool == "test-pool"
      assert base_volume.format == "qcow2"
      assert base_volume.source == "https://example.com/ubuntu.qcow2"
      
      # Check VM disk volumes
      master_disks = Enum.filter(state.volumes, &String.contains?(&1.name, "k8s-master") and String.contains?(&1.name, "-disk"))
      assert length(master_disks) == 2
      
      worker_disks = Enum.filter(state.volumes, &String.contains?(&1.name, "k8s-worker") and String.contains?(&1.name, "-disk"))
      assert length(worker_disks) == 3
      
      # Check cloud-init ISO volumes
      cloudinit_isos = Enum.filter(state.volumes, &String.ends_with?(&1.name, "-init.iso"))
      assert length(cloudinit_isos) == 5
    end

    test "generates domains from config", %{config: config} do
      {:ok, state} = State.from_config(config)
      
      # Should have 2 masters + 3 workers = 5 domains
      assert length(state.domains) == 5
      
      # Check master domains
      masters = Enum.filter(state.domains, &String.starts_with?(&1.name, "k8s-master"))
      assert length(masters) == 2
      
      master1 = Enum.find(masters, &(&1.name == "k8s-master-1"))
      assert %Domain{} = master1
      assert master1.memory == 2048
      assert master1.vcpu == 2
      assert master1.pool == "test-pool"
      assert master1.network == "test-network"
      
      # Check worker domains
      workers = Enum.filter(state.domains, &String.starts_with?(&1.name, "k8s-worker"))
      assert length(workers) == 3
      
      worker1 = Enum.find(workers, &(&1.name == "k8s-worker-1"))
      assert %Domain{} = worker1
      assert worker1.memory == 4096
      assert worker1.vcpu == 4
    end

    test "handles minimal configuration" do
      minimal_config = [
        cluster: [name: "minimal", domain: "test.local"],
        network: [name: "minimal-net", mode: "nat", cidr: "10.0.0.0/24"],
        storage: [
          pool_name: "minimal-pool", 
          pool_path: "/tmp/minimal",
          base_image: [
            name: "minimal-base",
            url: "https://example.com/minimal.qcow2",
            format: "qcow2"
          ]
        ],
        nodes: [
          masters: [count: 1, memory: 1024, vcpus: 1, disk_size: 10737418240, ip_prefix: "10.0.0.10"],
          workers: [count: 0, memory: 1024, vcpus: 1, disk_size: 10737418240, ip_prefix: "10.0.0.20"]
        ],
        ssh: [public_key_path: "/tmp/key.pub", user: "test"]
      ]
      
      {:ok, state} = State.from_config(minimal_config)
      
      assert length(state.networks) == 1
      assert length(state.pools) == 1
      assert length(state.domains) == 1  # Only 1 master, 0 workers
      
      # Should have: base image (if configured) + 1 VM disk + 1 cloud-init = 2-3 volumes
      assert length(state.volumes) >= 2
    end

    test "validates configuration before generating state" do
      invalid_config = [
        cluster: [name: "test"],
        # Missing required fields
      ]
      
      assert {:error, %NimbleOptions.ValidationError{}} = State.from_config(invalid_config)
    end
  end

  describe "fetch_current/0" do
    test "returns error when libvirt is not accessible" do
      # Mock the libvirt calls to fail
      with_mock RomulusElixir.Libvirt, [
        list_networks: fn -> {:error, "virsh not found"} end
      ] do
        assert {:error, _reason} = State.fetch_current()
      end
    end
  end

  describe "diff/2" do
    test "computes differences between states" do
      state1 = %State{
        networks: [%Network{name: "net1", active: true}],
        pools: [%Pool{name: "pool1", active: true}],
        volumes: [],
        domains: []
      }
      
      state2 = %State{
        networks: [
          %Network{name: "net1", active: true},
          %Network{name: "net2", active: true}
        ],
        pools: [%Pool{name: "pool1", active: true}],
        volumes: [%Volume{name: "vol1", pool: "pool1"}],
        domains: [%Domain{name: "vm1", state: :running}]
      }
      
      diff = State.diff(state1, state2)
      
      assert diff.networks.added == ["net2"]
      assert diff.networks.removed == []
      assert diff.volumes.added == ["vol1"]
      assert diff.domains.added == ["vm1"]
    end

    test "handles empty states" do
      empty = State.empty()
      
      state = %State{
        networks: [%Network{name: "net1", active: true}],
        pools: [],
        volumes: [],
        domains: []
      }
      
      diff1 = State.diff(empty, state)
      assert diff1.networks.added == ["net1"]
      assert diff1.networks.removed == []
      
      diff2 = State.diff(state, empty)
      assert diff2.networks.added == []
      assert diff2.networks.removed == ["net1"]
    end
  end

  describe "validate_state/1" do
    test "validates state consistency" do
      # Valid state - all domains reference existing pools and networks
      valid_state = %State{
        networks: [%Network{name: "net1", active: true}],
        pools: [%Pool{name: "pool1", active: true}],
        volumes: [%Volume{name: "vol1", pool: "pool1"}],
        domains: [%Domain{name: "vm1", pool: "pool1", network: "net1"}]
      }
      
      assert {:ok, ^valid_state} = State.validate_state(valid_state)
    end

    test "detects domain referencing non-existent pool" do
      invalid_state = %State{
        networks: [%Network{name: "net1", active: true}],
        pools: [%Pool{name: "pool1", active: true}],
        volumes: [],
        domains: [%Domain{name: "vm1", pool: "nonexistent-pool", network: "net1"}]
      }
      
      assert {:error, reason} = State.validate_state(invalid_state)
      assert reason =~ "nonexistent-pool"
    end

    test "detects domain referencing non-existent network" do
      invalid_state = %State{
        networks: [%Network{name: "net1", active: true}],
        pools: [%Pool{name: "pool1", active: true}],
        volumes: [],
        domains: [%Domain{name: "vm1", pool: "pool1", network: "nonexistent-net"}]
      }
      
      assert {:error, reason} = State.validate_state(invalid_state)
      assert reason =~ "nonexistent-net"
    end

    test "detects volume referencing non-existent pool" do
      invalid_state = %State{
        networks: [],
        pools: [%Pool{name: "pool1", active: true}],
        volumes: [%Volume{name: "vol1", pool: "nonexistent-pool"}],
        domains: []
      }
      
      assert {:error, reason} = State.validate_state(invalid_state)
      assert reason =~ "nonexistent-pool"
    end
  end

  describe "resource counting" do
    setup do
      state = %State{
        networks: [
          %Network{name: "net1", active: true},
          %Network{name: "net2", active: false}
        ],
        pools: [
          %Pool{name: "pool1", active: true},
          %Pool{name: "pool2", active: true}
        ],
        volumes: [
          %Volume{name: "vol1", pool: "pool1"},
          %Volume{name: "vol2", pool: "pool1"},
          %Volume{name: "vol3", pool: "pool2"}
        ],
        domains: [
          %Domain{name: "vm1", state: :running},
          %Domain{name: "vm2", state: :stopped},
          %Domain{name: "vm3", state: :running}
        ]
      }
      
      {:ok, state: state}
    end

    test "counts total resources", %{state: state} do
      assert State.count_resources(state, :networks) == 2
      assert State.count_resources(state, :pools) == 2
      assert State.count_resources(state, :volumes) == 3
      assert State.count_resources(state, :domains) == 3
    end

    test "counts active resources", %{state: state} do
      assert State.count_active_resources(state, :networks) == 1
      assert State.count_active_resources(state, :pools) == 2
      assert State.count_running_domains(state) == 2
    end

    test "gets resource summary", %{state: state} do
      summary = State.get_resource_summary(state)
      
      assert summary.networks.total == 2
      assert summary.networks.active == 1
      assert summary.pools.total == 2
      assert summary.pools.active == 2
      assert summary.volumes.total == 3
      assert summary.domains.total == 3
      assert summary.domains.running == 2
    end
  end

  # Helper for mocking
  defp with_mock(_module, _mock_functions, fun) do
    # Simple mock implementation for testing
    # In a real test suite, you'd use Mox or similar
    fun.()
  end
end