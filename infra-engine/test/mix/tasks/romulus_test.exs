defmodule Mix.Tasks.RomulusTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  alias Mix.Tasks.Romulus

  describe "plan task" do
    setup do
      # Create temporary config file
      config_dir = "test/fixtures/mix_tasks"
      config_file = Path.join(config_dir, "test_config.yaml")
      File.mkdir_p!(config_dir)
      
      config_content = """
      cluster:
        name: test-cluster
        domain: test.local
      network:
        name: test-network
        mode: nat
        cidr: "192.168.100.0/24"
        dhcp: true
        dns: true
      storage:
        pool_name: test-pool
        pool_path: /tmp/test-pool
        base_image:
          name: ubuntu-base
          url: https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img
          format: qcow2
      nodes:
        masters:
          count: 1
          memory: 2048
          vcpus: 2
          disk_size: 21474836480
          ip_prefix: "192.168.100.10"
        workers:
          count: 1
          memory: 4096
          vcpus: 4
          disk_size: 42949672960
          ip_prefix: "192.168.100.20"
      ssh:
        public_key_path: /tmp/test_key.pub
        private_key_path: /tmp/test_key
        user: ubuntu
      """
      
      File.write!(config_file, config_content)
      
      # Create dummy SSH key file
      File.write!("/tmp/test_key.pub", "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDtest test@test")
      
      on_exit(fn ->
        File.rm_rf!(config_dir)
        File.rm("/tmp/test_key.pub")
      end)
      
      {:ok, config_file: config_file}
    end

    test "displays plan output", %{config_file: config_file} do
      with_libvirt_mock([
        list_networks: {:ok, []},
        list_pools: {:ok, []},
        list_volumes: {:ok, []},
        list_domains: {:ok, []}
      ]) do
        output = capture_io(fn ->
          Romulus.Plan.run([config_file])
        end)
        
        assert output =~ "Plan Summary"
        assert output =~ "To create"
        assert output =~ "test-network"
        assert output =~ "test-pool"
      end
    end

    test "shows no changes when infrastructure matches", %{config_file: config_file} do
      # Mock existing infrastructure that matches config
      with_libvirt_mock([
        list_networks: {:ok, [%RomulusElixir.Libvirt.Network{name: "test-network"}]},
        list_pools: {:ok, [%RomulusElixir.Libvirt.Pool{name: "test-pool"}]},
        list_volumes: {:ok, []},  # Simplified
        list_domains: {:ok, []}   # Simplified
      ]) do
        output = capture_io(fn ->
          Romulus.Plan.run([config_file])
        end)
        
        assert output =~ "up to date" or output =~ "No changes"
      end
    end

    test "handles missing config file" do
      output = capture_io(:stderr, fn ->
        catch_exit(Romulus.Plan.run(["nonexistent.yaml"]))
      end)
      
      assert output =~ "not found" or output =~ "error"
    end

    test "plan task handles invalid config file" do
      invalid_config = "test/fixtures/invalid.yaml"
      File.write!(invalid_config, "invalid: yaml: [")
      
      try do
        output = capture_io(:stderr, fn ->
          Romulus.Plan.run([invalid_config])
        end)
        
        assert output =~ "Failed to parse" or output =~ "error" or output =~ "malformed"
      rescue
        SystemExit ->
          # Expected behavior for invalid config
          :ok
      after
        File.rm(invalid_config)
      end
    end
  end

  describe "apply task" do
    setup do
      config_dir = "test/fixtures/mix_tasks"
      config_file = Path.join(config_dir, "apply_test.yaml")
      File.mkdir_p!(config_dir)
      
      config_content = """
      cluster:
        name: apply-test-cluster
        domain: test.local
      network:
        name: apply-test-network
        mode: nat
        cidr: "192.168.101.0/24"
      storage:
        pool_name: apply-test-pool
        pool_path: /tmp/apply-test-pool
      nodes:
        masters:
          count: 1
          memory: 1024
          vcpus: 1
          disk_size: 10737418240
          ip_prefix: "192.168.101.10"
        workers:
          count: 0
          memory: 1024
          vcpus: 1
          disk_size: 10737418240
          ip_prefix: "192.168.101.20"
      ssh:
        public_key_path: /tmp/test_key.pub
        user: ubuntu
      """
      
      File.write!(config_file, config_content)
      File.write!("/tmp/test_key.pub", "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDtest test@test")
      
      on_exit(fn ->
        File.rm_rf!(config_dir)
        File.rm("/tmp/test_key.pub")
      end)
      
      {:ok, config_file: config_file}
    end

    test "prompts for confirmation by default", %{config_file: config_file} do
      with_libvirt_mock([
        list_networks: {:ok, []},
        list_pools: {:ok, []},
        list_volumes: {:ok, []},
        list_domains: {:ok, []}
      ]) do
        # Simulate user typing "no"
        input = "no\n"
        
        output = capture_io([input: input], fn ->
          catch_exit(Romulus.Apply.run([config_file]))
        end)
        
        assert output =~ "Do you want to continue?" or output =~ "Are you sure?"
        assert output =~ "Cancelled" or output =~ "Aborted"
      end
    end

    test "applies changes with --yes flag", %{config_file: config_file} do
      with_libvirt_mock([
        list_networks: {:ok, []},
        list_pools: {:ok, []},
        list_volumes: {:ok, []},
        list_domains: {:ok, []},
        create_network: {:ok, :created},
        create_pool: {:ok, :created},
        create_volume: :ok,
        create_domain: {:ok, :created}
      ]) do
        output = capture_io(fn ->
          Romulus.Apply.run([config_file, "--yes"])
        end)
        
        assert output =~ "Applying" or output =~ "Creating"
        assert output =~ "Success" or output =~ "Complete"
      end
    end

    test "handles apply failures gracefully", %{config_file: config_file} do
      with_libvirt_mock([
        list_networks: {:ok, []},
        list_pools: {:ok, []},
        list_volumes: {:ok, []},
        list_domains: {:ok, []},
        create_network: {:error, "Network creation failed"}
      ]) do
        output = capture_io(:stderr, fn ->
          catch_exit(Romulus.Apply.run([config_file, "--yes"]))
        end)
        
        assert output =~ "failed" or output =~ "error"
      end
    end
  end

  describe "destroy task" do
    setup do
      config_dir = "test/fixtures/mix_tasks"
      config_file = Path.join(config_dir, "destroy_test.yaml")
      File.mkdir_p!(config_dir)
      
      File.write!(config_file, """
      cluster:
        name: destroy-test
        domain: test.local
      network:
        name: destroy-test-network
        mode: nat
        cidr: "192.168.102.0/24"
      storage:
        pool_name: destroy-test-pool
        pool_path: /tmp/destroy-test-pool
      nodes:
        masters:
          count: 1
          memory: 1024
          vcpus: 1
          disk_size: 10737418240
          ip_prefix: "192.168.102.10"
        workers:
          count: 0
          memory: 1024
          vcpus: 1
          disk_size: 10737418240
          ip_prefix: "192.168.102.20"
      ssh:
        public_key_path: /tmp/test_key.pub
        user: ubuntu
      """)
      
      File.write!("/tmp/test_key.pub", "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDtest test@test")
      
      on_exit(fn ->
        File.rm_rf!(config_dir)
        File.rm("/tmp/test_key.pub")
      end)
      
      {:ok, config_file: config_file}
    end

    test "requires confirmation for destroy operation", %{config_file: config_file} do
      with_libvirt_mock([
        list_networks: {:ok, [%RomulusElixir.Libvirt.Network{name: "destroy-test-network"}]},
        list_pools: {:ok, [%RomulusElixir.Libvirt.Pool{name: "destroy-test-pool"}]},
        list_volumes: {:ok, []},
        list_domains: {:ok, []}
      ]) do
        # Simulate user typing wrong confirmation
        input = "wrong\nno\n"
        
        output = capture_io([input: input], fn ->
          catch_exit(Romulus.Destroy.run([config_file]))
        end)
        
        assert output =~ "destroy" and output =~ "confirm"
        assert output =~ "Cancelled" or output =~ "Aborted"
      end
    end

    test "destroys infrastructure with proper confirmation", %{config_file: config_file} do
      with_libvirt_mock([
        list_networks: {:ok, [%RomulusElixir.Libvirt.Network{name: "destroy-test-network"}]},
        list_pools: {:ok, [%RomulusElixir.Libvirt.Pool{name: "destroy-test-pool"}]},
        list_volumes: {:ok, []},
        list_domains: {:ok, []},
        delete_network: :ok,
        delete_pool: :ok
      ]) do
        # Simulate user typing correct confirmation
        input = "destroy\n"
        
        output = capture_io([input: input], fn ->
          Romulus.Destroy.run([config_file])
        end)
        
        assert output =~ "Destroying" or output =~ "Deleted"
        assert output =~ "destroy completed" or output =~ "Success"
      end
    end

    test "handles destroy with --force flag", %{config_file: config_file} do
      with_libvirt_mock([
        list_networks: {:ok, [%RomulusElixir.Libvirt.Network{name: "destroy-test-network"}]},
        list_pools: {:ok, []},
        list_volumes: {:ok, []},
        list_domains: {:ok, []},
        delete_network: :ok
      ]) do
        output = capture_io(fn ->
          Romulus.Destroy.run([config_file, "--force"])
        end)
        
        assert output =~ "Destroying" or output =~ "Force"
        refute output =~ "Are you sure" # Should skip confirmation
      end
    end
  end

  describe "health task" do
    test "performs basic health check" do
      with_libvirt_mock([
        list_networks: {:ok, [%RomulusElixir.Libvirt.Network{name: "default", active: true}]},
        list_pools: {:ok, [%RomulusElixir.Libvirt.Pool{name: "default", active: true}]},
        list_volumes: {:ok, []},
        list_domains: {:ok, [%RomulusElixir.Libvirt.Domain{name: "test-vm", state: :running}]}
      ]) do
        output = capture_io(fn ->
          Romulus.Health.run([])
        end)
        
        assert output =~ "Health Check" or output =~ "HEALTHY"
        assert output =~ "Networks:" or output =~ "network"
        assert output =~ "Pools:" or output =~ "pool"
      end
    end

    test "detects unhealthy infrastructure" do
      with_libvirt_mock([
        list_networks: {:ok, [%RomulusElixir.Libvirt.Network{name: "broken-net", active: false}]},
        list_pools: {:ok, []},
        list_volumes: {:ok, []},
        list_domains: {:ok, [%RomulusElixir.Libvirt.Domain{name: "stopped-vm", state: :stopped}]}
      ]) do
        output = capture_io(:stderr, fn ->
          catch_exit(Romulus.Health.run([]))
        end)
        
        assert output =~ "UNHEALTHY" or output =~ "DEGRADED" or output =~ "issues"
      end
    end

    test "outputs JSON format when requested" do
      with_libvirt_mock([
        list_networks: {:ok, []},
        list_pools: {:ok, []},
        list_volumes: {:ok, []},
        list_domains: {:ok, []}
      ]) do
        output = capture_io(fn ->
          Romulus.Health.run(["--format", "json"])
        end)
        
        assert output =~ "{"
        assert output =~ "status"
        assert output =~ "timestamp"
        
        # Verify it's valid JSON
        assert {:ok, _data} = Jason.decode(output)
      end
    end

    test "attempts auto-fix when requested" do
      with_libvirt_mock([
        list_networks: {:ok, [%RomulusElixir.Libvirt.Network{name: "inactive-net", active: false}]},
        list_pools: {:ok, []},
        list_volumes: {:ok, []},
        list_domains: {:ok, []},
        # Mock successful fix
        start_network: :ok
      ]) do
        output = capture_io(fn ->
          catch_exit(Romulus.Health.run(["--fix"]))
        end)
        
        assert output =~ "AUTO-FIX" or output =~ "fix"
      end
    end
  end

  describe "smoke_test task" do
    test "runs basic smoke tests" do
      with_libvirt_mock([
        list_networks: {:ok, [%RomulusElixir.Libvirt.Network{name: "default"}]},
        list_pools: {:ok, [%RomulusElixir.Libvirt.Pool{name: "default"}]},
        list_domains: {:ok, []},
        exists?: true
      ]) do
        output = capture_io(fn ->
          Romulus.SmokeTest.run([])
        end)
        
        assert output =~ "Smoke Test" or output =~ "PASSED"
        assert output =~ "libvirt" or output =~ "connectivity"
      end
    end

    test "detects when libvirt is not accessible" do
      with_system_mock([
        {"virsh version", {"error: failed to connect", 1}}
      ]) do
        output = capture_io(:stderr, fn ->
          catch_exit(Romulus.SmokeTest.run([]))
        end)
        
        assert output =~ "FAILED" or output =~ "failed to connect"
      end
    end
  end

  describe "heal task" do
    test "performs healing operations" do
      with_libvirt_mock([
        list_domains: {:ok, [%RomulusElixir.Libvirt.Domain{name: "stopped-vm", state: :stopped}]},
        start_domain: :ok
      ]) do
        output = capture_io(fn ->
          Romulus.Heal.run([])
        end)
        
        assert output =~ "Heal" or output =~ "healing"
        assert output =~ "START" or output =~ "starting"
      end
    end

    test "handles healing failures gracefully" do
      with_libvirt_mock([
        list_domains: {:ok, [%RomulusElixir.Libvirt.Domain{name: "broken-vm", state: :crashed}]},
        start_domain: {:error, "Cannot start crashed VM"}
      ]) do
        output = capture_io(fn ->
          Romulus.Heal.run([])
        end)
        
        assert output =~ "failed" or output =~ "error" or output =~ "Cannot start"
      end
    end
  end

  # Test helpers
  defp with_libvirt_mock(mock_responses, test_fun) do
    # Store original functions if any
    original_adapter = Application.get_env(:romulus_elixir, :libvirt_adapter, RomulusElixir.Libvirt)
    
    try do
      # Set up mocks
      :meck.new(RomulusElixir.Libvirt, [:passthrough])
      
      Enum.each(mock_responses, fn {function, response} ->
        case function do
          :list_networks ->
            :meck.expect(RomulusElixir.Libvirt, :list_networks, fn -> response end)
          :list_pools ->
            :meck.expect(RomulusElixir.Libvirt, :list_pools, fn -> response end)
          :list_volumes ->
            :meck.expect(RomulusElixir.Libvirt, :list_volumes, fn _pool -> response end)
          :list_domains ->
            :meck.expect(RomulusElixir.Libvirt, :list_domains, fn -> response end)
          :create_network ->
            :meck.expect(RomulusElixir.Libvirt, :create_network, fn _network -> response end)
          :create_pool ->
            :meck.expect(RomulusElixir.Libvirt, :create_pool, fn _pool -> response end)
          :create_volume ->
            :meck.expect(RomulusElixir.Libvirt, :create_volume, fn _volume -> response end)
          :create_domain ->
            :meck.expect(RomulusElixir.Libvirt, :create_domain, fn _domain -> response end)
          :delete_network ->
            :meck.expect(RomulusElixir.Libvirt, :delete_network, fn _name -> response end)
          :delete_pool ->
            :meck.expect(RomulusElixir.Libvirt, :delete_pool, fn _name -> response end)
          :start_domain ->
            :meck.expect(RomulusElixir.Libvirt, :start_domain, fn _name -> response end)
          :exists? ->
            :meck.expect(RomulusElixir.Libvirt, :exists?, fn _type, _name -> response end)
        end
      end)
      
      test_fun.()
    after
      :meck.unload(RomulusElixir.Libvirt)
    end
  end

  defp with_system_mock(command_responses, test_fun) do
    try do
      :meck.new(System, [:passthrough])
      
      :meck.expect(System, :cmd, fn command, args, _opts ->
        full_command = "#{command} #{Enum.join(args, " ")}"
        
        case Enum.find(command_responses, fn {cmd_pattern, _response} -> 
          String.contains?(full_command, cmd_pattern)
        end) do
          {_pattern, response} -> response
          nil -> {"command not mocked: #{full_command}", 1}
        end
      end)
      
      test_fun.()
    after
      :meck.unload(System)
    end
  end
end