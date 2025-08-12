defmodule RomulusElixir.StateComprehensiveTest do
  use ExUnit.Case, async: false

  alias RomulusElixir.State
  alias RomulusElixir.Libvirt
  alias RomulusElixir.Libvirt.{Network, Pool, Volume, Domain}
  import Mock

  describe "empty/0" do
    test "creates empty state with current timestamp" do
      before_time = DateTime.utc_now()
      state = State.empty()
      after_time = DateTime.utc_now()

      assert state.networks == []
      assert state.pools == []
      assert state.volumes == []
      assert state.domains == []
      assert DateTime.compare(state.timestamp, before_time) in [:eq, :gt]
      assert DateTime.compare(state.timestamp, after_time) in [:eq, :lt]
    end
  end

  describe "fetch_current/0" do
    test "successfully fetches current state from libvirt" do
      networks = [%Network{name: "default", active: true}]
      pools = [%Pool{name: "default", type: "dir", path: "/var/lib/libvirt/images"}]
      volumes = [%Volume{name: "vol1", pool: "default"}]
      domains = [%Domain{name: "vm1", memory: 1024, vcpu: 2}]

      with_mock Libvirt, [],
        list_networks: fn -> {:ok, networks} end,
        list_pools: fn -> {:ok, pools} end,
        list_volumes: fn -> {:ok, volumes} end,
        list_domains: fn -> {:ok, domains} end do

        assert {:ok, state} = State.fetch_current()
        
        assert state.networks == networks
        assert state.pools == pools
        assert state.volumes == volumes
        assert state.domains == domains
        assert %DateTime{} = state.timestamp
      end
    end

    test "handles network listing failure" do
      with_mock Libvirt, [],
        list_networks: fn -> {:error, "Connection failed"} end do

        assert {:error, "Connection failed"} = State.fetch_current()
      end
    end

    test "handles pool listing failure" do
      with_mock Libvirt, [],
        list_networks: fn -> {:ok, []} end,
        list_pools: fn -> {:error, "Pool error"} end do

        assert {:error, "Pool error"} = State.fetch_current()
      end
    end

    test "handles volume listing failure" do
      with_mock Libvirt, [],
        list_networks: fn -> {:ok, []} end,
        list_pools: fn -> {:ok, []} end,
        list_volumes: fn -> {:error, "Volume error"} end do

        assert {:error, "Volume error"} = State.fetch_current()
      end
    end

    test "handles domain listing failure" do
      with_mock Libvirt, [],
        list_networks: fn -> {:ok, []} end,
        list_pools: fn -> {:ok, []} end,
        list_volumes: fn -> {:ok, []} end,
        list_domains: fn -> {:error, "Domain error"} end do

        assert {:error, "Domain error"} = State.fetch_current()
      end
    end
  end

  describe "from_config/1" do
    test "generates desired state from complete configuration" do
      config = complete_config()
      
      assert {:ok, state} = State.from_config(config)
      
      # Validate networks
      assert length(state.networks) == 1
      network = List.first(state.networks)
      assert network.name == "k8s-network"
      assert network.mode == "nat"
      assert network.domain == "k8s.local"
      assert network.addresses == ["192.168.100.0/24"]
      assert network.dhcp == true
      assert network.dns == true
      
      # Validate pools
      assert length(state.pools) == 1
      pool = List.first(state.pools)
      assert pool.name == "k8s-storage"
      assert pool.type == "dir"
      assert pool.path == "/var/lib/libvirt/k8s-images"
      
      # Validate volumes (base + 3 masters + 2 workers + 5 cloudinit)
      assert length(state.volumes) == 11
      
      base_volume = Enum.find(state.volumes, &(&1.name == "ubuntu-20.04"))
      assert base_volume.pool == "k8s-storage"
      assert base_volume.source == "https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img"
      assert base_volume.format == "qcow2"
      
      # Check master volumes
      master_volumes = Enum.filter(state.volumes, &String.starts_with?(&1.name, "k8s-master"))
      disk_volumes = Enum.filter(master_volumes, &String.ends_with?(&1.name, "-disk"))
      cloudinit_volumes = Enum.filter(master_volumes, &String.ends_with?(&1.name, "-init.iso"))
      
      assert length(disk_volumes) == 3
      assert length(cloudinit_volumes) == 3
      
      Enum.each(disk_volumes, fn vol ->
        assert vol.pool == "k8s-storage"
        assert vol.base_volume == "ubuntu-20.04"
        assert vol.size == 21474836480
      end)
      
      Enum.each(cloudinit_volumes, fn vol ->
        assert vol.pool == "k8s-storage"
        assert vol.type == :cloudinit
        assert vol.node_type == :master
        assert vol.node_index in 1..3
      end)
      
      # Validate domains
      assert length(state.domains) == 5  # 3 masters + 2 workers
      
      masters = Enum.filter(state.domains, &String.starts_with?(&1.name, "k8s-master"))
      workers = Enum.filter(state.domains, &String.starts_with?(&1.name, "k8s-worker"))
      
      assert length(masters) == 3
      assert length(workers) == 2
      
      Enum.each(masters, fn domain ->
        assert domain.memory == 4096
        assert domain.vcpu == 2
        assert domain.network == "k8s-network"
        assert domain.pool == "k8s-storage"
        assert String.starts_with?(domain.ip_address, "192.168.100.1")
      end)
      
      Enum.each(workers, fn domain ->
        assert domain.memory == 8192
        assert domain.vcpu == 4
        assert domain.network == "k8s-network"
        assert domain.pool == "k8s-storage"
        assert String.starts_with?(domain.ip_address, "192.168.100.2")
      end)
    end

    test "generates state with zero master nodes" do
      config = complete_config()
      config = put_in(config, [:nodes, :masters, :count], 0)
      
      assert {:ok, state} = State.from_config(config)
      
      # Should have 2 workers only
      assert length(state.domains) == 2
      assert Enum.all?(state.domains, &String.starts_with?(&1.name, "k8s-worker"))
      
      # Should have base volume + 2 worker disks + 2 worker cloudinit
      assert length(state.volumes) == 5
      
      worker_volumes = Enum.filter(state.volumes, &String.starts_with?(&1.name, "k8s-worker"))
      assert length(worker_volumes) == 4  # 2 disks + 2 cloudinit
    end

    test "generates state with zero worker nodes" do
      config = complete_config()
      config = put_in(config, [:nodes, :workers, :count], 0)
      
      assert {:ok, state} = State.from_config(config)
      
      # Should have 3 masters only
      assert length(state.domains) == 3
      assert Enum.all?(state.domains, &String.starts_with?(&1.name, "k8s-master"))
      
      # Should have base volume + 3 master disks + 3 master cloudinit
      assert length(state.volumes) == 7
    end

    test "generates state with zero nodes" do
      config = complete_config()
      config = put_in(config, [:nodes, :masters, :count], 0)
      config = put_in(config, [:nodes, :workers, :count], 0)
      
      assert {:ok, state} = State.from_config(config)
      
      # Should have no domains
      assert state.domains == []
      
      # Should have only base volume
      assert length(state.volumes) == 1
      base_volume = List.first(state.volumes)
      assert base_volume.name == "ubuntu-20.04"
    end

    test "handles nil node counts as zero" do
      config = complete_config()
      config = put_in(config, [:nodes, :masters, :count], nil)
      config = put_in(config, [:nodes, :workers, :count], nil)
      
      assert {:ok, state} = State.from_config(config)
      
      assert state.domains == []
      assert length(state.volumes) == 1  # Only base volume
    end

    test "creates timestamp for generated state" do
      config = complete_config()
      before_time = DateTime.utc_now()
      
      assert {:ok, state} = State.from_config(config)
      
      after_time = DateTime.utc_now()
      assert DateTime.compare(state.timestamp, before_time) in [:eq, :gt]
      assert DateTime.compare(state.timestamp, after_time) in [:eq, :lt]
    end
  end

  describe "diff/2" do
    test "computes differences between two states" do
      state1 = %State{
        networks: [%Network{name: "net1"}, %Network{name: "net2"}],
        pools: [%Pool{name: "pool1"}],
        volumes: [%Volume{name: "vol1"}, %Volume{name: "vol2"}],
        domains: [%Domain{name: "vm1"}],
        timestamp: DateTime.utc_now()
      }
      
      state2 = %State{
        networks: [%Network{name: "net2"}, %Network{name: "net3"}],
        pools: [%Pool{name: "pool1"}, %Pool{name: "pool2"}],
        volumes: [%Volume{name: "vol2"}, %Volume{name: "vol3"}],
        domains: [%Domain{name: "vm2"}],
        timestamp: DateTime.utc_now()
      }
      
      diff = State.diff(state1, state2)
      
      # Networks: net1 removed, net3 added, net2 common
      assert diff.networks.removed == ["net1"]
      assert diff.networks.added == ["net3"]
      assert diff.networks.common == ["net2"]
      
      # Pools: pool2 added, pool1 common
      assert diff.pools.removed == []
      assert diff.pools.added == ["pool2"]
      assert diff.pools.common == ["pool1"]
      
      # Volumes: vol1 removed, vol3 added, vol2 common
      assert diff.volumes.removed == ["vol1"]
      assert diff.volumes.added == ["vol3"]
      assert diff.volumes.common == ["vol2"]
      
      # Domains: vm1 removed, vm2 added
      assert diff.domains.removed == ["vm1"]
      assert diff.domains.added == ["vm2"]
      assert diff.domains.common == []
      
      # Summary
      assert diff.summary.networks_removed == 1
      assert diff.summary.networks_added == 1
      assert diff.summary.pools_added == 1
      assert diff.summary.volumes_removed == 1
      assert diff.summary.volumes_added == 1
      assert diff.summary.domains_removed == 1
      assert diff.summary.domains_added == 1
    end

    test "handles identical states" do
      state1 = %State{
        networks: [%Network{name: "net1"}],
        pools: [%Pool{name: "pool1"}],
        volumes: [%Volume{name: "vol1"}],
        domains: [%Domain{name: "vm1"}],
        timestamp: DateTime.utc_now()
      }
      
      state2 = %State{
        networks: [%Network{name: "net1"}],
        pools: [%Pool{name: "pool1"}],
        volumes: [%Volume{name: "vol1"}],
        domains: [%Domain{name: "vm1"}],
        timestamp: DateTime.utc_now()
      }
      
      diff = State.diff(state1, state2)
      
      assert diff.networks.added == []
      assert diff.networks.removed == []
      assert diff.networks.common == ["net1"]
      
      assert diff.summary.networks_added == 0
      assert diff.summary.networks_removed == 0
      assert diff.summary.pools_added == 0
      assert diff.summary.pools_removed == 0
    end

    test "handles empty states" do
      empty1 = State.empty()
      empty2 = State.empty()
      
      diff = State.diff(empty1, empty2)
      
      assert diff.networks.added == []
      assert diff.networks.removed == []
      assert diff.networks.common == []
      assert diff.summary.networks_added == 0
    end
  end

  describe "validate_state/1" do
    test "validates state with correct references" do
      state = %State{
        networks: [%Network{name: "net1"}],
        pools: [%Pool{name: "pool1"}],
        volumes: [%Volume{name: "vol1", pool: "pool1"}],
        domains: [%Domain{name: "vm1", network: "net1", pool: "pool1"}],
        timestamp: DateTime.utc_now()
      }
      
      assert {:ok, ^state} = State.validate_state(state)
    end

    test "detects invalid domain network references" do
      state = %State{
        networks: [%Network{name: "net1"}],
        pools: [%Pool{name: "pool1"}],
        volumes: [],
        domains: [%Domain{name: "vm1", network: "nonexistent-net", pool: "pool1"}],
        timestamp: DateTime.utc_now()
      }
      
      assert {:error, reason} = State.validate_state(state)
      assert reason =~ "Domain 'vm1' references non-existent network 'nonexistent-net'"
    end

    test "detects invalid domain pool references" do
      state = %State{
        networks: [%Network{name: "net1"}],
        pools: [%Pool{name: "pool1"}],
        volumes: [],
        domains: [%Domain{name: "vm1", network: "net1", pool: "nonexistent-pool"}],
        timestamp: DateTime.utc_now()
      }
      
      assert {:error, reason} = State.validate_state(state)
      assert reason =~ "Domain 'vm1' references non-existent pool 'nonexistent-pool'"
    end

    test "detects invalid volume pool references" do
      state = %State{
        networks: [],
        pools: [%Pool{name: "pool1"}],
        volumes: [%Volume{name: "vol1", pool: "nonexistent-pool"}],
        domains: [],
        timestamp: DateTime.utc_now()
      }
      
      assert {:error, reason} = State.validate_state(state)
      assert reason =~ "Volume 'vol1' references non-existent pool 'nonexistent-pool'"
    end

    test "allows nil references" do
      state = %State{
        networks: [%Network{name: "net1"}],
        pools: [%Pool{name: "pool1"}],
        volumes: [%Volume{name: "vol1", pool: nil}],
        domains: [%Domain{name: "vm1", network: nil, pool: nil}],
        timestamp: DateTime.utc_now()
      }
      
      assert {:ok, ^state} = State.validate_state(state)
    end
  end

  describe "count_resources/2" do
    setup do
      state = %State{
        networks: [%Network{name: "net1"}, %Network{name: "net2"}],
        pools: [%Pool{name: "pool1"}],
        volumes: [%Volume{name: "vol1"}, %Volume{name: "vol2"}, %Volume{name: "vol3"}],
        domains: [%Domain{name: "vm1"}, %Domain{name: "vm2"}, %Domain{name: "vm3"}, %Domain{name: "vm4"}],
        timestamp: DateTime.utc_now()
      }
      
      {:ok, state: state}
    end

    test "counts networks correctly", %{state: state} do
      assert State.count_resources(state, :networks) == 2
    end

    test "counts pools correctly", %{state: state} do
      assert State.count_resources(state, :pools) == 1
    end

    test "counts volumes correctly", %{state: state} do
      assert State.count_resources(state, :volumes) == 3
    end

    test "counts domains correctly", %{state: state} do
      assert State.count_resources(state, :domains) == 4
    end

    test "returns 0 for unknown resource types", %{state: state} do
      assert State.count_resources(state, :unknown) == 0
      assert State.count_resources(state, :invalid) == 0
    end
  end

  describe "count_active_resources/2" do
    setup do
      state = %State{
        networks: [
          %Network{name: "net1", active: true},
          %Network{name: "net2", active: false},
          %Network{name: "net3", active: true}
        ],
        pools: [
          %Pool{name: "pool1", active: true},
          %Pool{name: "pool2", active: false}
        ],
        volumes: [%Volume{name: "vol1"}, %Volume{name: "vol2"}],
        domains: [
          %Domain{name: "vm1", state: :running},
          %Domain{name: "vm2", state: :stopped},
          %Domain{name: "vm3", state: :running},
          %Domain{name: "vm4", state: :paused}
        ],
        timestamp: DateTime.utc_now()
      }
      
      {:ok, state: state}
    end

    test "counts active networks correctly", %{state: state} do
      assert State.count_active_resources(state, :networks) == 2
    end

    test "counts active pools correctly", %{state: state} do
      assert State.count_active_resources(state, :pools) == 1
    end

    test "counts running domains correctly", %{state: state} do
      assert State.count_active_resources(state, :domains) == 2
    end

    test "returns 0 for volumes (no active state)", %{state: state} do
      assert State.count_active_resources(state, :volumes) == 0
    end

    test "returns 0 for unknown resource types", %{state: state} do
      assert State.count_active_resources(state, :unknown) == 0
    end
  end

  describe "count_running_domains/1" do
    test "counts running domains correctly" do
      state = %State{
        networks: [],
        pools: [],
        volumes: [],
        domains: [
          %Domain{name: "vm1", state: :running},
          %Domain{name: "vm2", state: :stopped},
          %Domain{name: "vm3", state: :running},
          %Domain{name: "vm4", state: :paused},
          %Domain{name: "vm5", state: :running}
        ],
        timestamp: DateTime.utc_now()
      }
      
      assert State.count_running_domains(state) == 3
    end

    test "returns 0 when no domains are running" do
      state = %State{
        networks: [],
        pools: [],
        volumes: [],
        domains: [
          %Domain{name: "vm1", state: :stopped},
          %Domain{name: "vm2", state: :paused}
        ],
        timestamp: DateTime.utc_now()
      }
      
      assert State.count_running_domains(state) == 0
    end

    test "returns 0 when no domains exist" do
      state = State.empty()
      assert State.count_running_domains(state) == 0
    end
  end

  describe "get_resource_summary/1" do
    test "generates complete resource summary" do
      state = %State{
        networks: [
          %Network{name: "net1", active: true},
          %Network{name: "net2", active: false}
        ],
        pools: [
          %Pool{name: "pool1", active: true},
          %Pool{name: "pool2", active: true},
          %Pool{name: "pool3", active: false}
        ],
        volumes: [
          %Volume{name: "vol1"},
          %Volume{name: "vol2"}
        ],
        domains: [
          %Domain{name: "vm1", state: :running},
          %Domain{name: "vm2", state: :running},
          %Domain{name: "vm3", state: :stopped},
          %Domain{name: "vm4", state: :paused}
        ],
        timestamp: DateTime.utc_now()
      }
      
      summary = State.get_resource_summary(state)
      
      assert summary.networks.total == 2
      assert summary.networks.active == 1
      
      assert summary.pools.total == 3
      assert summary.pools.active == 2
      
      assert summary.volumes.total == 2
      
      assert summary.domains.total == 4
      assert summary.domains.running == 2
      assert summary.domains.stopped == 2  # total - running
    end

    test "handles empty state" do
      state = State.empty()
      summary = State.get_resource_summary(state)
      
      assert summary.networks.total == 0
      assert summary.networks.active == 0
      assert summary.pools.total == 0
      assert summary.pools.active == 0
      assert summary.volumes.total == 0
      assert summary.domains.total == 0
      assert summary.domains.running == 0
      assert summary.domains.stopped == 0
    end
  end

  # Helper functions

  defp complete_config do
    [
      cluster: [name: "k8s-cluster", domain: "k8s.local"],
      network: [
        name: "k8s-network",
        mode: "nat",
        cidr: "192.168.100.0/24",
        dhcp: true,
        dns: true
      ],
      storage: [
        pool_name: "k8s-storage",
        pool_path: "/var/lib/libvirt/k8s-images",
        base_image: [
          name: "ubuntu-20.04",
          url: "https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img",
          format: "qcow2"
        ]
      ],
      nodes: [
        masters: [
          count: 3,
          memory: 4096,
          vcpus: 2,
          disk_size: 21474836480,
          ip_prefix: "192.168.100.10"
        ],
        workers: [
          count: 2,
          memory: 8192,
          vcpus: 4,
          disk_size: 42949672960,
          ip_prefix: "192.168.100.20"
        ]
      ],
      ssh: [
        public_key_path: "/tmp/test_key.pub",
        private_key_path: "/tmp/test_key",
        user: "ubuntu"
      ]
    ]
  end
end
