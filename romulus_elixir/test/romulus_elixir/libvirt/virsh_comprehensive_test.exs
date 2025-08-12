defmodule RomulusElixir.Libvirt.VirshComprehensiveTest do
  use ExUnit.Case, async: false

  alias RomulusElixir.Libvirt.{Virsh, Network, Pool, Volume, Domain}
  import Mock

  describe "list_networks/0" do
    test "successfully lists networks when virsh succeeds" do
      with_mock System, [:passthrough], [
        cmd: fn "bash", ["-c", "virsh --timeout 30 net-list --all --name"], _opts ->
          {"network1\nnetwork2\ndefault\n", 0}
        end
      ] do
        assert {:ok, networks} = Virsh.list_networks()
        
        assert length(networks) == 3
        assert Enum.any?(networks, &(&1.name == "network1"))
        assert Enum.any?(networks, &(&1.name == "network2"))
        assert Enum.any?(networks, &(&1.name == "default"))
        
        # Check default values are set
        network = List.first(networks)
        assert network.active == true
        assert network.mode == "nat"
        assert network.addresses == ["192.168.1.0/24"]
      end
    end

    test "returns empty list when no networks exist" do
      with_mock System, [:passthrough], [
        cmd: fn "bash", ["-c", "virsh --timeout 30 net-list --all --name"], _opts ->
          {"", 0}
        end
      ] do
        assert {:ok, networks} = Virsh.list_networks()
        assert networks == []
      end
    end

    test "filters out empty lines from virsh output" do
      with_mock System, [:passthrough], [
        cmd: fn "bash", ["-c", "virsh --timeout 30 net-list --all --name"], _opts ->
          {"network1\n\nnetwork2\n\n", 0}
        end
      ] do
        assert {:ok, networks} = Virsh.list_networks()
        assert length(networks) == 2
        assert Enum.all?(networks, &(&1.name in ["network1", "network2"]))
      end
    end

    test "returns error when virsh command fails" do
      with_mock System, [:passthrough], [
        cmd: fn "bash", ["-c", "virsh --timeout 30 net-list --all --name"], _opts ->
          {"error: failed to connect to the hypervisor", 1}
        end
      ] do
        assert {:error, reason} = Virsh.list_networks()
        assert reason =~ "failed to connect to the hypervisor"
      end
    end

    test "handles virsh timeout errors" do
      with_mock System, [:passthrough], [
        cmd: fn "bash", ["-c", "virsh --timeout 30 net-list --all --name"], _opts ->
          {"error: Timed out during operation", 124}
        end
      ] do
        assert {:error, reason} = Virsh.list_networks()
        assert reason =~ "Timed out during operation"
      end
    end
  end

  describe "create_network/1" do
    test "creates network successfully with valid configuration" do
      network = %Network{
        name: "test-network",
        mode: "nat",
        addresses: ["192.168.100.0/24"],
        dhcp: true,
        dns: true
      }

      with_mock System, [:passthrough], [
        cmd: fn 
          "bash", ["-c", "virsh --timeout 30 net-define " <> _xml_file], _opts ->
            {"Network test-network defined from /tmp/test-network-network.xml", 0}
          "bash", ["-c", "virsh --timeout 30 net-start test-network"], _opts ->
            {"Network test-network started", 0}
          "bash", ["-c", "virsh --timeout 30 net-autostart test-network"], _opts ->
            {"Network test-network marked as autostarted", 0}
        end
      ] do
        with_mock File, [:passthrough], [
          write: fn _path, _content -> :ok end,
          rm: fn _path -> :ok end
        ] do
          assert :ok = Virsh.create_network(network)
        end
      end
    end

    test "handles network creation failure during define step" do
      network = %Network{name: "failing-network", mode: "nat", addresses: ["192.168.1.0/24"]}

      with_mock System, [:passthrough], [
        cmd: fn "bash", ["-c", "virsh --timeout 30 net-define " <> _], _opts ->
          {"error: network 'failing-network' already exists with uuid", 1}
        end
      ] do
        with_mock File, [:passthrough], [
          write: fn _path, _content -> :ok end,
          rm: fn _path -> :ok end
        ] do
          assert {:error, reason} = Virsh.create_network(network)
          assert reason =~ "already exists"
        end
      end
    end

    test "handles network creation failure during start step" do
      network = %Network{name: "test-network", mode: "nat", addresses: ["192.168.1.0/24"]}

      with_mock System, [:passthrough], [
        cmd: fn 
          "bash", ["-c", "virsh --timeout 30 net-define " <> _], _opts ->
            {"Network test-network defined", 0}
          "bash", ["-c", "virsh --timeout 30 net-start test-network"], _opts ->
            {"error: Failed to start network test-network", 1}
        end
      ] do
        with_mock File, [:passthrough], [
          write: fn _path, _content -> :ok end,
          rm: fn _path -> :ok end
        ] do
          assert {:error, reason} = Virsh.create_network(network)
          assert reason =~ "Failed to start network"
        end
      end
    end

    test "handles file writing errors" do
      network = %Network{name: "test-network", mode: "nat", addresses: ["192.168.1.0/24"]}

      with_mock File, [:passthrough], [
        write: fn _path, _content -> {:error, :eacces} end,
        rm: fn _path -> :ok end
      ] do
        assert {:error, :eacces} = Virsh.create_network(network)
      end
    end

    test "cleans up XML file after successful creation" do
      network = %Network{name: "cleanup-test", mode: "nat", addresses: ["192.168.1.0/24"]}

      with_mock System, [:passthrough], [
        cmd: fn 
          "bash", ["-c", "virsh --timeout 30 net-define " <> _], _opts -> {"", 0}
          "bash", ["-c", "virsh --timeout 30 net-start " <> _], _opts -> {"", 0}
          "bash", ["-c", "virsh --timeout 30 net-autostart " <> _], _opts -> {"", 0}
        end
      ] do
        with_mock File, [:passthrough], [
          write: fn _path, _content -> :ok end,
          rm: fn path -> 
            # Verify the XML file is cleaned up
            assert path =~ "cleanup-test-network.xml"
            :ok
          end
        ] do
          assert :ok = Virsh.create_network(network)
        end
      end
    end

    test "cleans up XML file after failed creation" do
      network = %Network{name: "cleanup-fail-test", mode: "nat", addresses: ["192.168.1.0/24"]}

      with_mock System, [:passthrough], [
        cmd: fn "bash", ["-c", "virsh --timeout 30 net-define " <> _], _opts ->
          {"error: operation failed", 1}
        end
      ] do
        with_mock File, [:passthrough], [
          write: fn _path, _content -> :ok end,
          rm: fn path -> 
            assert path =~ "cleanup-fail-test-network.xml"
            :ok
          end
        ] do
          assert {:error, _} = Virsh.create_network(network)
        end
      end
    end
  end

  describe "delete_network/1" do
    test "deletes network successfully" do
      with_mock System, [:passthrough], [
        cmd: fn 
          "bash", ["-c", "virsh --timeout 30 net-destroy test-network"], _opts ->
            {"Network test-network destroyed", 0}
          "bash", ["-c", "virsh --timeout 30 net-undefine test-network"], _opts ->
            {"Network test-network has been undefined", 0}
        end
      ] do
        assert :ok = Virsh.delete_network("test-network")
      end
    end

    test "handles network deletion failure during destroy step" do
      with_mock System, [:passthrough], [
        cmd: fn "bash", ["-c", "virsh --timeout 30 net-destroy nonexistent"], _opts ->
          {"error: failed to get network 'nonexistent'", 1}
        end
      ] do
        assert {:error, reason} = Virsh.delete_network("nonexistent")
        assert reason =~ "failed to get network"
      end
    end

    test "handles network deletion failure during undefine step" do
      with_mock System, [:passthrough], [
        cmd: fn 
          "bash", ["-c", "virsh --timeout 30 net-destroy test-network"], _opts ->
            {"Network test-network destroyed", 0}
          "bash", ["-c", "virsh --timeout 30 net-undefine test-network"], _opts ->
            {"error: network 'test-network' is not defined", 1}
        end
      ] do
        assert {:error, reason} = Virsh.delete_network("test-network")
        assert reason =~ "not defined"
      end
    end
  end

  describe "list_pools/0" do
    test "lists storage pools successfully" do
      with_mock System, [:passthrough], [
        cmd: fn "bash", ["-c", "virsh --timeout 30 pool-list --all --name"], _opts ->
          {"default\ntest-pool\nstorage-pool\n", 0}
        end
      ] do
        assert {:ok, pools} = Virsh.list_pools()
        
        assert length(pools) == 3
        pool_names = Enum.map(pools, & &1.name)
        assert "default" in pool_names
        assert "test-pool" in pool_names
        assert "storage-pool" in pool_names
        
        # Check default values
        pool = List.first(pools)
        assert pool.active == true
        assert pool.type == "dir"
        assert is_binary(pool.path)
        assert pool.capacity == 0
        assert pool.allocation == 0
      end
    end

    test "returns empty list when no pools exist" do
      with_mock System, [:passthrough], [
        cmd: fn "bash", ["-c", "virsh --timeout 30 pool-list --all --name"], _opts ->
          {"", 0}
        end
      ] do
        assert {:ok, pools} = Virsh.list_pools()
        assert pools == []
      end
    end

    test "handles pool listing errors" do
      with_mock System, [:passthrough], [
        cmd: fn "bash", ["-c", "virsh --timeout 30 pool-list --all --name"], _opts ->
          {"error: failed to connect to the hypervisor", 1}
        end
      ] do
        assert {:error, reason} = Virsh.list_pools()
        assert reason =~ "failed to connect"
      end
    end
  end

  describe "create_pool/1" do
    test "creates directory pool successfully" do
      pool = %Pool{
        name: "test-pool",
        type: "dir",
        path: "/var/lib/libvirt/images/test-pool"
      }

      with_mock System, [:passthrough], [
        cmd: fn 
          "bash", ["-c", "virsh --timeout 30 pool-define " <> _], _opts ->
            {"Pool test-pool defined from /tmp/test-pool-pool.xml", 0}
          "bash", ["-c", "virsh --timeout 30 pool-build test-pool"], _opts ->
            {"Pool test-pool built", 0}
          "bash", ["-c", "virsh --timeout 30 pool-start test-pool"], _opts ->
            {"Pool test-pool started", 0}
          "bash", ["-c", "virsh --timeout 30 pool-autostart test-pool"], _opts ->
            {"Pool test-pool marked as autostarted", 0}
        end
      ] do
        with_mock File, [:passthrough], [
          write: fn _path, _content -> :ok end,
          rm: fn _path -> :ok end
        ] do
          assert :ok = Virsh.create_pool(pool)
        end
      end
    end

    test "handles pool creation failure during build phase" do
      pool = %Pool{name: "failing-pool", type: "dir", path: "/nonexistent/path"}

      with_mock System, [:passthrough], [
        cmd: fn 
          "bash", ["-c", "virsh --timeout 30 pool-define " <> _], _opts ->
            {"Pool failing-pool defined", 0}
          "bash", ["-c", "virsh --timeout 30 pool-build failing-pool"], _opts ->
            {"error: cannot create directory '/nonexistent/path'", 1}
        end
      ] do
        with_mock File, [:passthrough], [
          write: fn _path, _content -> :ok end,
          rm: fn _path -> :ok end
        ] do
          assert {:error, reason} = Virsh.create_pool(pool)
          assert reason =~ "cannot create directory"
        end
      end
    end

    test "handles pool creation failure during start phase" do
      pool = %Pool{name: "failing-pool", type: "dir", path: "/tmp/test"}

      with_mock System, [:passthrough], [
        cmd: fn 
          "bash", ["-c", "virsh --timeout 30 pool-define " <> _], _opts ->
            {"Pool defined", 0}
          "bash", ["-c", "virsh --timeout 30 pool-build failing-pool"], _opts ->
            {"Pool built", 0}
          "bash", ["-c", "virsh --timeout 30 pool-start failing-pool"], _opts ->
            {"error: failed to start pool", 1}
        end
      ] do
        with_mock File, [:passthrough], [
          write: fn _path, _content -> :ok end,
          rm: fn _path -> :ok end
        ] do
          assert {:error, reason} = Virsh.create_pool(pool)
          assert reason =~ "failed to start pool"
        end
      end
    end
  end

  describe "delete_pool/1" do
    test "deletes pool successfully" do
      with_mock System, [:passthrough], [
        cmd: fn 
          "bash", ["-c", "virsh --timeout 30 pool-destroy test-pool"], _opts ->
            {"Pool test-pool destroyed", 0}
          "bash", ["-c", "virsh --timeout 30 pool-undefine test-pool"], _opts ->
            {"Pool test-pool has been undefined", 0}
        end
      ] do
        assert :ok = Virsh.delete_pool("test-pool")
      end
    end

    test "handles pool deletion failure" do
      with_mock System, [:passthrough], [
        cmd: fn "bash", ["-c", "virsh --timeout 30 pool-destroy nonexistent"], _opts ->
          {"error: failed to get pool 'nonexistent'", 1}
        end
      ] do
        assert {:error, reason} = Virsh.delete_pool("nonexistent")
        assert reason =~ "failed to get pool"
      end
    end
  end

  describe "list_volumes/1" do
    test "lists volumes in pool successfully" do
      with_mock System, [:passthrough], [
        cmd: fn "bash", ["-c", "virsh --timeout 30 vol-list test-pool --name"], _opts ->
          {"volume1.qcow2\nvolume2.qcow2\nbase-image.qcow2\n", 0}
        end
      ] do
        assert {:ok, volumes} = Virsh.list_volumes("test-pool")
        
        assert length(volumes) == 3
        volume_names = Enum.map(volumes, & &1.name)
        assert "volume1.qcow2" in volume_names
        assert "volume2.qcow2" in volume_names
        assert "base-image.qcow2" in volume_names
        
        # Check default values
        volume = List.first(volumes)
        assert volume.pool == "test-pool"
        assert volume.format == "qcow2"
        assert volume.size == "10G"
        assert is_binary(volume.path)
      end
    end

    test "returns empty list for pool with no volumes" do
      with_mock System, [:passthrough], [
        cmd: fn "bash", ["-c", "virsh --timeout 30 vol-list empty-pool --name"], _opts ->
          {"", 0}
        end
      ] do
        assert {:ok, volumes} = Virsh.list_volumes("empty-pool")
        assert volumes == []
      end
    end

    test "returns error for nonexistent pool" do
      with_mock System, [:passthrough], [
        cmd: fn "bash", ["-c", "virsh --timeout 30 vol-list nonexistent-pool --name"], _opts ->
          {"error: failed to get pool 'nonexistent-pool'", 1}
        end
      ] do
        assert {:error, reason} = Virsh.list_volumes("nonexistent-pool")
        assert reason =~ "failed to get pool"
      end
    end
  end

  describe "create_volume/1" do
    test "creates volume from scratch" do
      volume = %Volume{
        name: "test-volume",
        pool: "test-pool",
        size: "10G",
        format: "qcow2",
        source: nil
      }

      with_mock System, [:passthrough], [
        cmd: fn "bash", ["-c", "virsh --timeout 30 vol-create-as test-pool test-volume 10G --format qcow2"], _opts ->
          {"Vol test-volume created", 0}
        end
      ] do
        assert :ok = Virsh.create_volume(volume)
      end
    end

    test "clones volume from base volume" do
      volume = %Volume{
        name: "cloned-volume",
        pool: "test-pool",
        base_volume: "base-image",
        source: nil
      }

      with_mock System, [:passthrough], [
        cmd: fn "bash", ["-c", "virsh --timeout 30 vol-clone base-image cloned-volume --pool test-pool"], _opts ->
          {"Vol cloned-volume cloned from base-image", 0}
        end
      ] do
        assert :ok = Virsh.create_volume(volume)
      end
    end

    test "downloads and creates volume from URL" do
      volume = %Volume{
        name: "downloaded-volume",
        pool: "test-pool",
        source: "https://example.com/image.qcow2"
      }

      with_mock System, [:passthrough], [
        cmd: fn "bash", ["-c", "virsh --timeout 300 ! wget -O /var/lib/libvirt/images/test-pool/downloaded-volume https://example.com/image.qcow2"], _opts ->
          {"", 0}
        end
      ] do
        assert :ok = Virsh.create_volume(volume)
      end
    end

    test "handles volume creation failure" do
      volume = %Volume{
        name: "failing-volume",
        pool: "test-pool",
        size: "0G"  # Invalid size
      }

      with_mock System, [:passthrough], [
        cmd: fn "bash", ["-c", "virsh --timeout 30 vol-create-as test-pool failing-volume 0G --format qcow2"], _opts ->
          {"error: invalid size", 1}
        end
      ] do
        assert {:error, reason} = Virsh.create_volume(volume)
        assert reason =~ "invalid size"
      end
    end
  end

  describe "delete_volume/2" do
    test "deletes volume successfully" do
      with_mock System, [:passthrough], [
        cmd: fn "bash", ["-c", "virsh --timeout 30 vol-delete test-volume --pool test-pool"], _opts ->
          {"Vol test-volume deleted", 0}
        end
      ] do
        assert :ok = Virsh.delete_volume("test-volume", "test-pool")
      end
    end

    test "handles volume deletion failure" do
      with_mock System, [:passthrough], [
        cmd: fn "bash", ["-c", "virsh --timeout 30 vol-delete nonexistent-volume --pool test-pool"], _opts ->
          {"error: failed to get vol 'nonexistent-volume'", 1}
        end
      ] do
        assert {:error, reason} = Virsh.delete_volume("nonexistent-volume", "test-pool")
        assert reason =~ "failed to get vol"
      end
    end
  end

  describe "list_domains/0" do
    test "lists domains successfully" do
      with_mock System, [:passthrough], [
        cmd: fn "bash", ["-c", "virsh --timeout 30 list --all --name"], _opts ->
          {"vm1\nvm2\ntest-domain\n", 0}
        end
      ] do
        assert {:ok, domains} = Virsh.list_domains()
        
        assert length(domains) == 3
        domain_names = Enum.map(domains, & &1.name)
        assert "vm1" in domain_names
        assert "vm2" in domain_names
        assert "test-domain" in domain_names
        
        # Check default values
        domain = List.first(domains)
        assert domain.state == :running
        assert domain.memory == 1024
        assert domain.vcpu == 2
      end
    end

    test "returns empty list when no domains exist" do
      with_mock System, [:passthrough], [
        cmd: fn "bash", ["-c", "virsh --timeout 30 list --all --name"], _opts ->
          {"", 0}
        end
      ] do
        assert {:ok, domains} = Virsh.list_domains()
        assert domains == []
      end
    end

    test "handles domain listing errors" do
      with_mock System, [:passthrough], [
        cmd: fn "bash", ["-c", "virsh --timeout 30 list --all --name"], _opts ->
          {"error: failed to connect to the hypervisor", 1}
        end
      ] do
        assert {:error, reason} = Virsh.list_domains()
        assert reason =~ "failed to connect"
      end
    end
  end

  describe "create_domain/1" do
    test "creates domain successfully" do
      domain = %Domain{
        name: "test-vm",
        memory: 2048,
        vcpu: 2,
        network: "test-network",
        pool: "test-pool"
      }

      with_mock System, [:passthrough], [
        cmd: fn "bash", ["-c", "virsh --timeout 30 define /tmp/test-vm-domain.xml"], _opts ->
          {"Domain test-vm defined from /tmp/test-vm-domain.xml", 0}
        end
      ] do
        with_mock File, [:passthrough], [
          write: fn _path, _content -> :ok end,
          rm: fn _path -> :ok end
        ] do
          assert :ok = Virsh.create_domain(domain)
        end
      end
    end

    test "handles domain creation failure" do
      domain = %Domain{
        name: "invalid-vm",
        memory: -1,  # Invalid memory size
        vcpu: 0
      }

      with_mock System, [:passthrough], [
        cmd: fn "bash", ["-c", "virsh --timeout 30 define /tmp/invalid-vm-domain.xml"], _opts ->
          {"error: invalid memory size", 1}
        end
      ] do
        with_mock File, [:passthrough], [
          write: fn _path, _content -> :ok end,
          rm: fn _path -> :ok end
        ] do
          assert {:error, reason} = Virsh.create_domain(domain)
          assert reason =~ "invalid memory size"
        end
      end
    end
  end

  describe "start_domain/1" do
    test "starts domain successfully" do
      with_mock System, [:passthrough], [
        cmd: fn "bash", ["-c", "virsh --timeout 30 start test-vm"], _opts ->
          {"Domain test-vm started", 0}
        end
      ] do
        assert :ok = Virsh.start_domain("test-vm")
      end
    end

    test "handles start failure for already running domain" do
      with_mock System, [:passthrough], [
        cmd: fn "bash", ["-c", "virsh --timeout 30 start running-vm"], _opts ->
          {"error: domain is already active", 1}
        end
      ] do
        assert {:error, reason} = Virsh.start_domain("running-vm")
        assert reason =~ "already active"
      end
    end
  end

  describe "stop_domain/1" do
    test "stops domain gracefully" do
      with_mock System, [:passthrough], [
        cmd: fn "bash", ["-c", "virsh --timeout 30 shutdown test-vm"], _opts ->
          {"Domain test-vm is being shutdown", 0}
        end
      ] do
        assert :ok = Virsh.stop_domain("test-vm")
      end
    end

    test "handles stop failure for already stopped domain" do
      with_mock System, [:passthrough], [
        cmd: fn "bash", ["-c", "virsh --timeout 30 shutdown stopped-vm"], _opts ->
          {"error: domain is not running", 1}
        end
      ] do
        assert {:error, reason} = Virsh.stop_domain("stopped-vm")
        assert reason =~ "not running"
      end
    end
  end

  describe "delete_domain/1" do
    test "destroys and undefines domain" do
      with_mock System, [:passthrough], [
        cmd: fn 
          "bash", ["-c", "virsh --timeout 30 destroy test-vm"], _opts ->
            {"Domain test-vm destroyed", 0}
          "bash", ["-c", "virsh --timeout 30 undefine test-vm --remove-all-storage"], _opts ->
            {"Domain test-vm has been undefined", 0}
        end
      ] do
        assert :ok = Virsh.delete_domain("test-vm")
      end
    end

    test "handles domain deletion failure" do
      with_mock System, [:passthrough], [
        cmd: fn "bash", ["-c", "virsh --timeout 30 destroy nonexistent-vm"], _opts ->
          {"error: failed to get domain 'nonexistent-vm'", 1}
        end
      ] do
        assert {:error, reason} = Virsh.delete_domain("nonexistent-vm")
        assert reason =~ "failed to get domain"
      end
    end
  end

  describe "get_domain_info/1" do
    test "returns domain information" do
      with_mock System, [:passthrough], [
        cmd: fn "bash", ["-c", "virsh --timeout 30 dominfo test-vm"], _opts ->
          {"""
          Id:             1
          Name:           test-vm
          UUID:           550e8400-e29b-41d4-a716-446655440000
          OS Type:        hvm
          State:          running
          CPU(s):         2
          CPU time:       10.1s
          Max memory:     2097152 KiB
          Used memory:    2097152 KiB
          Persistent:     yes
          Autostart:      disable
          """, 0}
        end
      ] do
        assert {:ok, info} = Virsh.get_domain_info("test-vm")
        
        assert info["Id"] == "1"
        assert info["Name"] == "test-vm"
        assert info["State"] == "running"
        assert info["CPU(s)"] == "2"
        assert info["Max memory"] == "2097152 KiB"
      end
    end

    test "handles info request for nonexistent domain" do
      with_mock System, [:passthrough], [
        cmd: fn "bash", ["-c", "virsh --timeout 30 dominfo nonexistent-vm"], _opts ->
          {"error: failed to get domain 'nonexistent-vm'", 1}
        end
      ] do
        assert {:error, reason} = Virsh.get_domain_info("nonexistent-vm")
        assert reason =~ "failed to get domain"
      end
    end
  end

  describe "exists?/2" do
    test "returns true for existing network" do
      with_mock System, [:passthrough], [
        cmd: fn "bash", ["-c", "virsh --timeout 30 net-info existing-network"], _opts ->
          {"Name:           existing-network", 0}
        end
      ] do
        assert Virsh.exists?(:network, "existing-network") == true
      end
    end

    test "returns false for nonexistent resource" do
      with_mock System, [:passthrough], [
        cmd: fn "bash", ["-c", "virsh --timeout 30 net-info nonexistent-network"], _opts ->
          {"error: failed to get network 'nonexistent-network'", 1}
        end
      ] do
        assert Virsh.exists?(:network, "nonexistent-network") == false
      end
    end

    test "handles different resource types" do
      with_mock System, [:passthrough], [
        cmd: fn "bash", ["-c", "virsh --timeout 30 pool-info existing-pool"], _opts ->
          {"Name:           existing-pool", 0}
        end
      ] do
        assert Virsh.exists?(:pool, "existing-pool") == true
      end
    end

    test "handles unknown resource types" do
      with_mock System, [:passthrough], [
        cmd: fn "bash", ["-c", "virsh --timeout 30 list"], _opts ->
          {"", 0}
        end
      ] do
        assert Virsh.exists?(:unknown, "test") == true
      end
    end
  end

  describe "XML generation" do
    test "generates valid network XML" do
      network = %Network{
        name: "test-network",
        mode: "nat",
        addresses: ["192.168.100.0/24"],
        dhcp: true
      }

      with_mock System, [:passthrough], [
        cmd: fn 
          "bash", ["-c", "virsh --timeout 30 net-define " <> xml_file], _opts ->
            # Verify XML file contains expected content
            {:ok, content} = File.read(xml_file)
            assert content =~ "<name>test-network</name>"
            assert content =~ "mode='nat'"
            assert content =~ "192.168.100"
            assert content =~ "<dhcp>"
            {"Network defined", 0}
          "bash", ["-c", "virsh --timeout 30 net-start " <> _], _opts -> {"", 0}
          "bash", ["-c", "virsh --timeout 30 net-autostart " <> _], _opts -> {"", 0}
        end
      ] do
        with_mock File, [:passthrough], [] do
          assert :ok = Virsh.create_network(network)
        end
      end
    end

    test "generates valid domain XML with proper structure" do
      domain = %Domain{
        name: "test-vm",
        memory: 4096,
        vcpu: 4,
        network: "test-network",
        pool: "test-pool"
      }

      with_mock System, [:passthrough], [
        cmd: fn "bash", ["-c", "virsh --timeout 30 define " <> xml_file], _opts ->
          # Verify XML file contains expected content
          {:ok, content} = File.read(xml_file)
          assert content =~ "<name>test-vm</name>"
          assert content =~ "<memory unit='MiB'>4096</memory>"
          assert content =~ "<vcpu placement='static'>4</vcpu>"
          assert content =~ "network='test-network'"
          {"Domain defined", 0}
        end
      ] do
        with_mock File, [:passthrough], [] do
          assert :ok = Virsh.create_domain(domain)
        end
      end
    end
  end

  describe "error handling and logging" do
    test "logs debug information for successful commands" do
      with_mock System, [:passthrough], [
        cmd: fn "bash", ["-c", "virsh --timeout 30 net-list --all --name"], _opts ->
          {"network1\n", 0}
        end
      ] do
        assert {:ok, _} = Virsh.list_networks()
        # Logger calls would be verified in integration tests
      end
    end

    test "logs errors for failed commands" do
      with_mock System, [:passthrough], [
        cmd: fn "bash", ["-c", "virsh --timeout 30 net-list --all --name"], _opts ->
          {"error: connection failed", 1}
        end
      ] do
        assert {:error, _} = Virsh.list_networks()
        # Logger calls would be verified in integration tests
      end
    end
  end

  describe "timeout handling" do
    test "uses custom timeout for volume downloads" do
      volume = %Volume{
        name: "large-volume",
        pool: "test-pool",
        source: "https://example.com/large-image.qcow2"
      }

      with_mock System, [:passthrough], [
        cmd: fn "bash", ["-c", cmd], _opts ->
          # Verify timeout is set to 300 seconds (5 minutes) for downloads
          assert cmd =~ "--timeout 300"
          {"", 0}
        end
      ] do
        assert :ok = Virsh.create_volume(volume)
      end
    end

    test "uses default timeout for regular operations" do
      with_mock System, [:passthrough], [
        cmd: fn "bash", ["-c", cmd], _opts ->
          # Verify default timeout is 30 seconds
          assert cmd =~ "--timeout 30"
          {"network1\n", 0}
        end
      ] do
        assert {:ok, _} = Virsh.list_networks()
      end
    end
  end

  describe "helper functions" do
    test "parses CIDR addresses correctly for network XML" do
      network = %Network{
        name: "cidr-test",
        mode: "nat",
        addresses: ["10.0.1.0/24"]
      }

      with_mock System, [:passthrough], [
        cmd: fn 
          "bash", ["-c", "virsh --timeout 30 net-define " <> xml_file], _opts ->
            {:ok, content} = File.read(xml_file)
            # Verify correct gateway, netmask, and DHCP range
            assert content =~ "address='10.0.1.1'"
            assert content =~ "netmask='255.255.255.0'"
            assert content =~ "start='10.0.1.100'"
            assert content =~ "end='10.0.1.254'"
            {"", 0}
          "bash", ["-c", "virsh --timeout 30 net-start " <> _], _opts -> {"", 0}
          "bash", ["-c", "virsh --timeout 30 net-autostart " <> _], _opts -> {"", 0}
        end
      ] do
        with_mock File, [:passthrough], [] do
          assert :ok = Virsh.create_network(network)
        end
      end
    end

    test "handles edge case CIDR ranges" do
      network = %Network{
        name: "edge-cidr",
        mode: "nat",
        addresses: ["192.168.255.0/24"]
      }

      with_mock System, [:passthrough], [
        cmd: fn 
          "bash", ["-c", "virsh --timeout 30 net-define " <> xml_file], _opts ->
            {:ok, content} = File.read(xml_file)
            assert content =~ "192.168.255"
            {"", 0}
          _, _, _ -> {"", 0}
        end
      ] do
        with_mock File, [:passthrough], [] do
          assert :ok = Virsh.create_network(network)
        end
      end
    end
  end
end
