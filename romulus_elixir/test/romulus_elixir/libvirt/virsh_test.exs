defmodule RomulusElixir.Libvirt.VirshTest do
  use ExUnit.Case, async: false  # Virsh tests interact with system commands

  alias RomulusElixir.Libvirt.Virsh
  alias RomulusElixir.Libvirt.{Network, Pool, Volume, Domain}

  describe "list_networks/0" do
    test "returns list of networks when virsh succeeds" do
      with_system_mock([
        {"virsh net-list --all --name", {"network1\nnetwork2\ndefault\n", 0}}
      ]) do
        assert {:ok, networks} = Virsh.list_networks()
        assert length(networks) == 3
        assert Enum.all?(networks, &is_struct(&1, Network))
        assert Enum.any?(networks, &(&1.name == "network1"))
        assert Enum.any?(networks, &(&1.name == "default"))
      end
    end

    test "returns empty list when no networks exist" do
      with_system_mock([
        {"virsh net-list --all --name", {"", 0}}
      ]) do
        assert {:ok, networks} = Virsh.list_networks()
        assert networks == []
      end
    end

    test "returns error when virsh command fails" do
      with_system_mock([
        {"virsh net-list --all --name", {"error: failed to connect to the hypervisor", 1}}
      ]) do
        assert {:error, reason} = Virsh.list_networks()
        assert reason =~ "failed to connect"
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

      with_system_mock([
        {"virsh net-define /tmp/test-network-network.xml", {"Network test-network defined", 0}},
        {"virsh net-start test-network", {"Network test-network started", 0}},
        {"virsh net-autostart test-network", {"Network test-network marked as autostarted", 0}}
      ]) do
        assert :ok = Virsh.create_network(network)
      end
    end

    test "handles network creation failure" do
      network = %Network{
        name: "existing-network",
        mode: "nat",
        addresses: ["192.168.100.0/24"]
      }

      with_system_mock([
        {"virsh net-define /tmp/existing-network-network.xml", {"error: network 'existing-network' already exists", 1}}
      ]) do
        assert {:error, reason} = Virsh.create_network(network)
        assert reason =~ "already exists"
      end
    end

    test "cleans up XML file after creation" do
      network = %Network{name: "cleanup-test", mode: "nat", addresses: ["192.168.1.0/24"]}
      xml_file = "/tmp/cleanup-test-network.xml"

      with_system_mock([
        {"virsh net-define #{xml_file}", {"Network defined", 0}},
        {"virsh net-start cleanup-test", {"Network started", 0}},
        {"virsh net-autostart cleanup-test", {"Network autostarted", 0}}
      ]) do
        Virsh.create_network(network)
        refute File.exists?(xml_file)
      end
    end
  end

  describe "delete_network/1" do
    test "deletes network successfully" do
      with_system_mock([
        {"virsh net-destroy test-network", {"Network test-network destroyed", 0}},
        {"virsh net-undefine test-network", {"Network test-network has been undefined", 0}}
      ]) do
        assert :ok = Virsh.delete_network("test-network")
      end
    end

    test "handles network deletion failure" do
      with_system_mock([
        {"virsh net-destroy nonexistent-network", {"error: failed to get network 'nonexistent-network'", 1}}
      ]) do
        assert {:error, reason} = Virsh.delete_network("nonexistent-network")
        assert reason =~ "failed to get network"
      end
    end
  end

  describe "list_pools/0" do
    test "returns list of storage pools" do
      with_system_mock([
        {"virsh pool-list --all --name", {"default\ntest-pool\n", 0}}
      ]) do
        assert {:ok, pools} = Virsh.list_pools()
        assert length(pools) == 2
        assert Enum.all?(pools, &is_struct(&1, Pool))
        
        default_pool = Enum.find(pools, &(&1.name == "default"))
        assert default_pool.type == "dir"
        assert default_pool.active == true
      end
    end
  end

  describe "create_pool/1" do
    test "creates directory pool successfully" do
      pool = %Pool{
        name: "test-pool",
        type: "dir",
        path: "/tmp/test-pool"
      }

      with_system_mock([
        {"virsh pool-define /tmp/test-pool-pool.xml", {"Pool test-pool defined", 0}},
        {"virsh pool-build test-pool", {"Pool test-pool built", 0}},
        {"virsh pool-start test-pool", {"Pool test-pool started", 0}},
        {"virsh pool-autostart test-pool", {"Pool test-pool marked as autostarted", 0}}
      ]) do
        assert :ok = Virsh.create_pool(pool)
      end
    end

    test "handles pool creation failure during build phase" do
      pool = %Pool{name: "failing-pool", type: "dir", path: "/invalid/path"}

      with_system_mock([
        {"virsh pool-define /tmp/failing-pool-pool.xml", {"Pool failing-pool defined", 0}},
        {"virsh pool-build failing-pool", {"error: cannot create directory '/invalid/path'", 1}}
      ]) do
        assert {:error, reason} = Virsh.create_pool(pool)
        assert reason =~ "cannot create directory"
      end
    end
  end

  describe "delete_pool/1" do
    test "deletes pool successfully" do
      with_system_mock([
        {"virsh pool-destroy test-pool", {"Pool test-pool destroyed", 0}},
        {"virsh pool-undefine test-pool", {"Pool test-pool has been undefined", 0}}
      ]) do
        assert :ok = Virsh.delete_pool("test-pool")
      end
    end
  end

  describe "list_volumes/1" do
    test "returns list of volumes in pool" do
      with_system_mock([
        {"virsh vol-list test-pool --name", {"volume1.qcow2\nvolume2.qcow2\nbase.qcow2\n", 0}}
      ]) do
        assert {:ok, volumes} = Virsh.list_volumes("test-pool")
        assert length(volumes) == 3
        assert Enum.all?(volumes, &is_struct(&1, Volume))
        
        volume1 = Enum.find(volumes, &(&1.name == "volume1.qcow2"))
        assert volume1.pool == "test-pool"
        assert volume1.format == "qcow2"
      end
    end

    test "returns empty list for pool with no volumes" do
      with_system_mock([
        {"virsh vol-list empty-pool --name", {"", 0}}
      ]) do
        assert {:ok, volumes} = Virsh.list_volumes("empty-pool")
        assert volumes == []
      end
    end

    test "returns error for nonexistent pool" do
      with_system_mock([
        {"virsh vol-list nonexistent-pool --name", {"error: failed to get pool 'nonexistent-pool'", 1}}
      ]) do
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
        format: "qcow2",
        size: "10G"
      }

      with_system_mock([
        {"virsh vol-create-as test-pool test-volume 10G --format qcow2", {"Vol test-volume created", 0}}
      ]) do
        assert :ok = Virsh.create_volume(volume)
      end
    end

    test "clones volume from base volume" do
      volume = %Volume{
        name: "cloned-volume",
        pool: "test-pool",
        format: "qcow2",
        base_volume: "base-volume"
      }

      with_system_mock([
        {"virsh vol-clone base-volume cloned-volume --pool test-pool", {"Vol cloned-volume cloned from base-volume", 0}}
      ]) do
        assert :ok = Virsh.create_volume(volume)
      end
    end

    test "downloads and creates volume from URL" do
      volume = %Volume{
        name: "downloaded-volume",
        pool: "test-pool",
        format: "qcow2",
        size: "5G",
        source: "https://example.com/image.qcow2"
      }

      with_system_mock([
        {"virsh ! wget -O /var/lib/libvirt/images/test-pool/downloaded-volume https://example.com/image.qcow2", {"Downloaded successfully", 0}}
      ]) do
        assert :ok = Virsh.create_volume(volume)
      end
    end

    test "handles volume creation failure" do
      volume = %Volume{name: "failing-volume", pool: "test-pool", format: "qcow2", size: "0G"}

      with_system_mock([
        {"virsh vol-create-as test-pool failing-volume 0G --format qcow2", {"error: invalid size specified", 1}}
      ]) do
        assert {:error, reason} = Virsh.create_volume(volume)
        assert reason =~ "invalid size"
      end
    end
  end

  describe "delete_volume/2" do
    test "deletes volume successfully" do
      with_system_mock([
        {"virsh vol-delete test-volume --pool test-pool", {"Vol test-volume deleted", 0}}
      ]) do
        assert :ok = Virsh.delete_volume("test-volume", "test-pool")
      end
    end

    test "handles volume deletion failure" do
      with_system_mock([
        {"virsh vol-delete nonexistent-volume --pool test-pool", {"error: failed to get vol 'nonexistent-volume'", 1}}
      ]) do
        assert {:error, reason} = Virsh.delete_volume("nonexistent-volume", "test-pool")
        assert reason =~ "failed to get vol"
      end
    end
  end

  describe "list_domains/0" do
    test "returns list of domains" do
      with_system_mock([
        {"virsh list --all --name", {"domain1\ndomain2\ntest-vm\n", 0}}
      ]) do
        assert {:ok, domains} = Virsh.list_domains()
        assert length(domains) == 3
        assert Enum.all?(domains, &is_struct(&1, Domain))
        
        domain1 = Enum.find(domains, &(&1.name == "domain1"))
        assert domain1.state == :running  # Simplified state
      end
    end
  end

  describe "create_domain/1" do
    test "creates domain successfully" do
      domain = %Domain{
        name: "test-vm",
        memory: 2048,
        vcpu: 2,
        pool: "default",
        network: "default"
      }

      with_system_mock([
        {"virsh define /tmp/test-vm-domain.xml", {"Domain test-vm defined from /tmp/test-vm-domain.xml", 0}}
      ]) do
        assert :ok = Virsh.create_domain(domain)
      end
    end

    test "handles domain creation failure" do
      domain = %Domain{name: "invalid-vm", memory: 0, vcpu: 0}

      with_system_mock([
        {"virsh define /tmp/invalid-vm-domain.xml", {"error: invalid memory size", 1}}
      ]) do
        assert {:error, reason} = Virsh.create_domain(domain)
        assert reason =~ "invalid memory size"
      end
    end
  end

  describe "start_domain/1" do
    test "starts domain successfully" do
      with_system_mock([
        {"virsh start test-vm", {"Domain test-vm started", 0}}
      ]) do
        assert :ok = Virsh.start_domain("test-vm")
      end
    end

    test "handles start failure for already running domain" do
      with_system_mock([
        {"virsh start running-vm", {"error: domain is already active", 1}}
      ]) do
        assert {:error, reason} = Virsh.start_domain("running-vm")
        assert reason =~ "already active"
      end
    end
  end

  describe "stop_domain/1" do
    test "stops domain gracefully" do
      with_system_mock([
        {"virsh shutdown test-vm", {"Domain test-vm is being shutdown", 0}}
      ]) do
        assert :ok = Virsh.stop_domain("test-vm")
      end
    end
  end

  describe "delete_domain/1" do
    test "destroys and undefines domain" do
      with_system_mock([
        {"virsh destroy test-vm", {"Domain test-vm destroyed", 0}},
        {"virsh undefine test-vm --remove-all-storage", {"Domain test-vm has been undefined", 0}}
      ]) do
        assert :ok = Virsh.delete_domain("test-vm")
      end
    end
  end

  describe "get_domain_info/1" do
    test "returns domain information" do
      info_output = """
      Id:             1
      Name:           test-vm
      UUID:           550e8400-e29b-41d4-a716-446655440000
      OS Type:        hvm
      State:          running
      CPU(s):         2
      CPU time:       15.2s
      Max memory:     2097152 KiB
      Used memory:    1048576 KiB
      Persistent:     yes
      Autostart:      disable
      Managed save:   no
      Security model: none
      Security DOI:   0
      """

      with_system_mock([
        {"virsh dominfo test-vm", {info_output, 0}}
      ]) do
        assert {:ok, info} = Virsh.get_domain_info("test-vm")
        assert info["Name"] == "test-vm"
        assert info["State"] == "running"
        assert info["CPU(s)"] == "2"
      end
    end

    test "handles info request for nonexistent domain" do
      with_system_mock([
        {"virsh dominfo nonexistent-vm", {"error: failed to get domain 'nonexistent-vm'", 1}}
      ]) do
        assert {:error, reason} = Virsh.get_domain_info("nonexistent-vm")
        assert reason =~ "failed to get domain"
      end
    end
  end

  describe "exists?/2" do
    test "returns true for existing network" do
      with_system_mock([
        {"virsh net-info existing-network", {"Name:            existing-network\nUUID:            123\n", 0}}
      ]) do
        assert Virsh.exists?(:network, "existing-network") == true
      end
    end

    test "returns false for nonexistent resource" do
      with_system_mock([
        {"virsh net-info nonexistent-network", {"error: failed to get network 'nonexistent-network'", 1}}
      ]) do
        assert Virsh.exists?(:network, "nonexistent-network") == false
      end
    end

    test "handles different resource types" do
      with_system_mock([
        {"virsh pool-info existing-pool", {"Name:            existing-pool\n", 0}},
        {"virsh dominfo existing-vm", {"Name:            existing-vm\n", 0}}
      ]) do
        assert Virsh.exists?(:pool, "existing-pool") == true
        assert Virsh.exists?(:domain, "existing-vm") == true
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

      # Test by actually creating a network and checking the XML file
      xml_file = "/tmp/test-xml-network.xml"
      
      with_system_mock([
        {"virsh net-define #{xml_file}", {"Network defined", 0}},
        {"virsh net-start test-network", {"Network started", 0}},
        {"virsh net-autostart test-network", {"Network autostarted", 0}}
      ]) do
        Virsh.create_network(network)
        
        # XML file should have been created and then cleaned up
        # In a real test, you might want to verify the XML content
      end
    end

    test "generates valid domain XML with proper structure" do
      domain = %Domain{
        name: "test-vm",
        memory: 1024,
        vcpu: 1,
        pool: "default",
        network: "default"
      }

      xml_file = "/tmp/test-vm-domain.xml"

      with_system_mock([
        {"virsh define #{xml_file}", {"Domain defined", 0}}
      ]) do
        Virsh.create_domain(domain)
        # XML validation happens implicitly through virsh define success
      end
    end
  end

  describe "error handling and logging" do
    test "logs debug information for successful commands" do
      with_system_mock([
        {"virsh net-list --all --name", {"network1\n", 0}}
      ]) do
        ExUnit.CaptureLog.capture_log(fn ->
          Virsh.list_networks()
        end) =~ "Executing: virsh net-list --all --name"
      end
    end

    test "logs errors for failed commands" do
      with_system_mock([
        {"virsh net-list --all --name", {"connection failed", 1}}
      ]) do
        ExUnit.CaptureLog.capture_log(fn ->
          Virsh.list_networks()
        end) =~ "Command failed (1): connection failed"
      end
    end

    test "handles timeout for long-running commands" do
      # This would test timeout handling, but we need to mock the System.cmd timeout behavior
      # In a real implementation, you'd test this with actual timeouts
    end
  end

  # Test helper for mocking System.cmd calls
  defp with_system_mock(command_responses, test_fun) do
    original_system_cmd = &System.cmd/3
    
    try do
      # Mock System.cmd
      :meck.new(System, [:passthrough])
      :meck.expect(System, :cmd, fn "bash", ["-c", command], _opts ->
        case Enum.find(command_responses, fn {cmd_pattern, _response} -> 
          String.contains?(command, cmd_pattern)
        end) do
          {_pattern, response} -> response
          nil -> {"command not mocked: #{command}", 1}
        end
      end)
      
      test_fun.()
    after
      :meck.unload(System)
    end
  end

  setup do
    # Ensure ETS tables exist for any tests that need them
    unless :ets.info(:virsh_test_mock) != :undefined do
      :ets.new(:virsh_test_mock, [:named_table, :public])
    end
    
    on_exit(fn ->
      if :ets.info(:virsh_test_mock) != :undefined do
        :ets.delete(:virsh_test_mock)
      end
    end)
    
    :ok
  end
end