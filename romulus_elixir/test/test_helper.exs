# Test configuration and setup for RomulusElixir

# Start ExUnit with configuration
ExUnit.start(
  capture_log: true,
  max_cases: System.schedulers_online(),
  exclude: [:slow, :integration],
  timeout: 30_000
)

# Ensure application is started for tests
Application.ensure_all_started(:romulus_elixir)

# Set up test fixtures directory
fixtures_dir = Path.join(__DIR__, "fixtures")
File.mkdir_p!(fixtures_dir)

# Create default test configuration file
test_config_path = Path.join(fixtures_dir, "romulus.yaml")
unless File.exists?(test_config_path) do
  test_config = """
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
      name: test-base
      url: https://example.com/test.qcow2
      format: qcow2
  nodes:
    masters:
      count: 1
      memory: 1024
      vcpus: 1
      disk_size: 5368709120
      ip_prefix: "192.168.100.10"
    workers:
      count: 1
      memory: 1024
      vcpus: 1
      disk_size: 5368709120
      ip_prefix: "192.168.100.20"
  ssh:
    public_key_path: /tmp/test_key.pub
    private_key_path: /tmp/test_key
    user: test
  """
  
  File.write!(test_config_path, test_config)
end

# Create test SSH key files
test_key_pub = "/tmp/test_key.pub"
test_key = "/tmp/test_key"

unless File.exists?(test_key_pub) do
  File.write!(test_key_pub, "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDtest test@test")
end

unless File.exists?(test_key) do
  File.write!(test_key, "-----BEGIN PRIVATE KEY-----\nTEST_PRIVATE_KEY\n-----END PRIVATE KEY-----")
  File.chmod!(test_key, 0o600)
end

# Clean up function for test teardown
defmodule TestHelper do
  @moduledoc """
  Helper functions for tests
  """

  @doc """
  Clean up test artifacts and temporary files
  """
  def cleanup_test_artifacts do
    # Clean up temporary test files
    File.rm("/tmp/test_key.pub")
    File.rm("/tmp/test_key")
    
    # Clean up test directories
    File.rm_rf("/tmp/test-pool")
    File.rm_rf("/tmp/romulus-test")
    File.rm_rf("/tmp/romulus-test-pools")
    File.rm_rf("/tmp/romulus-dev-pools")
    
    # Clean up any test-specific libvirt resources (if running integration tests)
    if System.get_env("ROMULUS_CLEANUP_LIBVIRT") == "true" do
      cleanup_libvirt_test_resources()
    end
  end

  @doc """
  Set up test environment for a specific test
  """
  def setup_test_env(test_name) do
    # Create test-specific temporary directory
    test_dir = Path.join("/tmp", "romulus-test-#{test_name}")
    File.mkdir_p!(test_dir)
    
    # Return cleanup function
    fn -> File.rm_rf!(test_dir) end
  end

  @doc """
  Create a temporary configuration file for testing
  """
  def create_test_config(config_map, test_name) do
    config_dir = Path.join([__DIR__, "fixtures", test_name])
    File.mkdir_p!(config_dir)
    
    config_file = Path.join(config_dir, "romulus.yaml")
    # Create YAML content manually since YamlElixir doesn't have write_to_string!
    yaml_content = create_yaml_from_map(config_map)
    File.write!(config_file, yaml_content)
    
    {config_file, fn -> File.rm_rf!(config_dir) end}
  end

  @doc """
  Mock libvirt operations for testing
  """
  def mock_libvirt(mock_responses) do
    # Set up ETS table for mock responses if not exists
    case :ets.info(:libvirt_mock) do
      :undefined -> :ets.new(:libvirt_mock, [:named_table, :public, :set])
      _ -> :ok
    end
    
    # Store mock responses
    Enum.each(mock_responses, fn {function, response} ->
      :ets.insert(:libvirt_mock, {function, response})
    end)
  end

  @doc """
  Clean up libvirt test resources (for integration tests)
  """
  def cleanup_libvirt_test_resources do
    try do
      # Only run if virsh is available
      case System.cmd("virsh", ["version"], stderr_to_stdout: true) do
        {_, 0} ->
          # Clean up test networks
          case System.cmd("virsh", ["net-list", "--name"], stderr_to_stdout: true) do
            {output, 0} ->
              output
              |> String.split("\n", trim: true)
              |> Enum.filter(&String.starts_with?(&1, "test-"))
              |> Enum.each(fn network ->
                System.cmd("virsh", ["net-destroy", network], stderr_to_stdout: true)
                System.cmd("virsh", ["net-undefine", network], stderr_to_stdout: true)
              end)
            _ -> :ok
          end
          
          # Clean up test pools
          case System.cmd("virsh", ["pool-list", "--name"], stderr_to_stdout: true) do
            {output, 0} ->
              output
              |> String.split("\n", trim: true)
              |> Enum.filter(&String.starts_with?(&1, "test-"))
              |> Enum.each(fn pool ->
                System.cmd("virsh", ["pool-destroy", pool], stderr_to_stdout: true)
                System.cmd("virsh", ["pool-undefine", pool], stderr_to_stdout: true)
              end)
            _ -> :ok
          end
          
          # Clean up test domains
          case System.cmd("virsh", ["list", "--all", "--name"], stderr_to_stdout: true) do
            {output, 0} ->
              output
              |> String.split("\n", trim: true)
              |> Enum.filter(&String.starts_with?(&1, "test-"))
              |> Enum.each(fn domain ->
                System.cmd("virsh", ["destroy", domain], stderr_to_stdout: true)
                System.cmd("virsh", ["undefine", domain, "--remove-all-storage"], stderr_to_stdout: true)
              end)
            _ -> :ok
          end
        _ -> :ok  # virsh not available, skip cleanup
      end
    rescue
      _ -> :ok  # Ignore cleanup errors
    end
  end
  
  # Helper function to create YAML content from a map
  defp create_yaml_from_map(config_map) do
    # Simple YAML generation for test configuration
    """
    cluster:
      name: #{config_map.cluster.name}
      domain: #{config_map.cluster.domain}
    network:
      name: #{config_map.network.name}
      mode: #{config_map.network.mode}
      cidr: "#{config_map.network.cidr}"
      dhcp: #{config_map.network.dhcp}
      dns: #{config_map.network.dns}
    storage:
      pool_name: #{config_map.storage.pool_name}
      pool_path: #{config_map.storage.pool_path}
      base_image:
        name: #{config_map.storage.base_image.name}
        url: #{config_map.storage.base_image.url}
        format: #{config_map.storage.base_image.format}
    nodes:
      masters:
        count: #{config_map.nodes.masters.count}
        memory: #{config_map.nodes.masters.memory}
        vcpus: #{config_map.nodes.masters.vcpus}
        disk_size: #{config_map.nodes.masters.disk_size}
        ip_prefix: "#{config_map.nodes.masters.ip_prefix}"
      workers:
        count: #{config_map.nodes.workers.count}
        memory: #{config_map.nodes.workers.memory}
        vcpus: #{config_map.nodes.workers.vcpus}
        disk_size: #{config_map.nodes.workers.disk_size}
        ip_prefix: "#{config_map.nodes.workers.ip_prefix}"
    ssh:
      public_key_path: #{config_map.ssh.public_key_path}
      private_key_path: #{config_map.ssh.private_key_path}
      user: #{config_map.ssh.user}
    """
  end
end

# Set up cleanup on exit
System.at_exit(fn _ ->
  TestHelper.cleanup_test_artifacts()
end)
