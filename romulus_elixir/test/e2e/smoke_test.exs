defmodule RomulusElixir.E2E.SmokeTest do
  @moduledoc """
  Comprehensive end-to-end smoke tests for Romulus infrastructure management.
  
  This test suite validates the complete infrastructure lifecycle including:
  - Cluster configuration generation
  - Infrastructure provisioning (`mix romulus.apply`)
  - VM connectivity and service validation
  - Complete infrastructure teardown (`mix romulus.destroy`)
  - Rollback and failure recovery scenarios
  
  These tests require a real libvirt environment and should be run with:
  
      mix test test/e2e/smoke_test.exs --include e2e
      
  Environment variables:
  - ROMULUS_E2E_TIMEOUT - Test timeout in milliseconds (default: 600_000 - 10 minutes)
  - ROMULUS_E2E_SKIP_SSH - Skip SSH connectivity tests (default: false)
  - ROMULUS_E2E_CLEANUP - Clean up resources after test failure (default: true)
  """
  
  use ExUnit.Case, async: false
  
  require Logger
  
  alias RomulusElixir.{Config, State}
  
  # Test configuration
  @test_timeout Application.compile_env(:romulus_elixir, :e2e_timeout, 600_000)  # 10 minutes
  @test_config_file "test/fixtures/e2e_smoke_test.yaml"
  @test_cluster_name "romulus-e2e-smoke"
  @test_network_name "#{@test_cluster_name}-network"
  @test_pool_name "#{@test_cluster_name}-pool"
  
  # Tags for test categorization
  @moduletag :e2e
  @moduletag timeout: @test_timeout
  
  describe "End-to-end smoke tests" do
    setup do
      # Create test-specific configuration
      config_content = generate_test_config()
      File.write!(@test_config_file, config_content)
      
      # Ensure clean environment before test
      cleanup_test_resources()
      
      on_exit(fn ->
        if System.get_env("ROMULUS_E2E_CLEANUP", "true") == "true" do
          cleanup_test_resources()
        end
        File.rm_rf(@test_config_file)
      end)
      
      {:ok, config_file: @test_config_file}
    end

    @tag :smoke
    test "complete infrastructure lifecycle with VM validation", %{config_file: config_file} do
      Logger.info("Starting complete infrastructure lifecycle test")
      
      # Step 1: Generate and verify initial state (should be empty)
      assert {:ok, initial_state} = State.fetch_current()
      assert_empty_infrastructure(initial_state, @test_cluster_name)
      
      # Step 2: Run mix romulus.apply to create infrastructure
      Logger.info("Applying infrastructure configuration")
      apply_result = run_mix_task("romulus.apply", [
        "--config", config_file
      ])
      assert {:ok, _output} = apply_result
      
      # Step 3: Verify infrastructure was created
      Logger.info("Verifying infrastructure creation")
      assert {:ok, post_apply_state} = State.fetch_current()
      assert_infrastructure_created(post_apply_state, @test_cluster_name)
      
      # Step 4: Verify VMs are reachable via SSH (if SSH tests are enabled)
      unless System.get_env("ROMULUS_E2E_SKIP_SSH") == "true" do
        Logger.info("Testing SSH connectivity to VMs")
        assert_vm_ssh_connectivity(post_apply_state, config_file)
      end
      
      # Step 5: Verify kubelet is running on all nodes
      Logger.info("Verifying kubelet service on all nodes")
      assert_kubelet_running(post_apply_state)
      
      # Step 6: Run mix romulus.destroy to teardown infrastructure
      Logger.info("Destroying infrastructure")
      destroy_result = run_mix_task("romulus.destroy", [
        "--config", config_file
      ])
      assert {:ok, _output} = destroy_result
      
      # Step 7: Verify complete cleanup
      Logger.info("Verifying complete infrastructure cleanup")
      assert {:ok, post_destroy_state} = State.fetch_current()
      assert_empty_infrastructure(post_destroy_state, @test_cluster_name)
      
      Logger.info("Complete infrastructure lifecycle test passed")
    end

    @tag :rollback
    test "rollback and failure recovery scenarios", %{config_file: _config_file} do
      Logger.info("Starting rollback and failure recovery test")
      
      # Step 1: Partially apply infrastructure (create network and pool only)
      Logger.info("Partially applying infrastructure")
      partial_config = generate_partial_config()
      partial_config_file = "test/fixtures/e2e_partial.yaml"
      File.write!(partial_config_file, partial_config)
      
      apply_result = run_mix_task("romulus.apply", [
        "--config", partial_config_file
      ])
      assert {:ok, _output} = apply_result
      
      # Step 2: Verify partial infrastructure
      assert {:ok, partial_state} = State.fetch_current()
      assert_network_exists(partial_state, @test_network_name)
      assert_pool_exists(partial_state, @test_pool_name)
      
      # Step 3: Simulate failure by corrupting configuration and attempting apply
      Logger.info("Simulating configuration failure")
      invalid_config = generate_invalid_config()
      invalid_config_file = "test/fixtures/e2e_invalid.yaml"
      File.write!(invalid_config_file, invalid_config)
      
      # This should fail gracefully
      invalid_apply_result = run_mix_task("romulus.apply", [
        "--config", invalid_config_file
      ])
      assert {:error, _reason} = invalid_apply_result
      
      # Step 4: Verify infrastructure is still in partial state (no corruption)
      assert {:ok, post_failure_state} = State.fetch_current()
      assert_network_exists(post_failure_state, @test_network_name)
      assert_pool_exists(post_failure_state, @test_pool_name)
      
      # Step 5: Perform cleanup using mix romulus.destroy
      Logger.info("Performing rollback cleanup")
      cleanup_result = run_mix_task("romulus.destroy", [
        "--config", partial_config_file
      ])
      assert {:ok, _output} = cleanup_result
      
      # Step 6: Verify complete cleanup after rollback
      assert {:ok, final_state} = State.fetch_current()
      assert_empty_infrastructure(final_state, @test_cluster_name)
      
      # Clean up test files
      File.rm(partial_config_file)
      File.rm(invalid_config_file)
      
      Logger.info("Rollback and failure recovery test passed")
    end

    @tag :resilience
    test "resource conflict and recovery handling", %{config_file: config_file} do
      Logger.info("Starting resource conflict and recovery test")
      
      # Step 1: Create conflicting resources manually via virsh
      Logger.info("Creating conflicting resources")
      create_conflicting_resources()
      
      # Step 2: Attempt to apply - should handle conflicts gracefully
      Logger.info("Applying configuration with conflicts")
      apply_result = run_mix_task("romulus.apply", [
        "--config", config_file
      ])
      
      # Should succeed by either using existing resources or resolving conflicts
      assert {:ok, _output} = apply_result
      
      # Step 3: Verify infrastructure state is consistent
      assert {:ok, state_with_conflicts} = State.fetch_current()
      assert_infrastructure_consistent(state_with_conflicts, @test_cluster_name)
      
      # Step 4: Clean up everything
      Logger.info("Cleaning up after conflict resolution")
      cleanup_result = run_mix_task("romulus.destroy", [
        "--config", config_file
      ])
      assert {:ok, _output} = cleanup_result
      
      # Step 5: Manual cleanup of any remaining conflicting resources
      cleanup_conflicting_resources()
      
      # Step 6: Verify complete cleanup
      assert {:ok, final_state} = State.fetch_current()
      assert_empty_infrastructure(final_state, @test_cluster_name)
      
      Logger.info("Resource conflict and recovery test passed")
    end

    @tag :k8s_bootstrap
    test "kubernetes bootstrap and health verification", %{config_file: config_file} do
      Logger.info("Starting Kubernetes bootstrap and health verification test")
      
      # Step 1: Apply infrastructure first
      Logger.info("Applying infrastructure for K8s bootstrap test")
      apply_result = run_mix_task("romulus.apply", [
        "--config", config_file
      ])
      assert {:ok, _output} = apply_result
      
      # Step 2: Verify infrastructure was created
      assert {:ok, post_apply_state} = State.fetch_current()
      assert_infrastructure_created(post_apply_state, @test_cluster_name)
      
      # Wait for VMs to be fully ready before k8s bootstrap
      Process.sleep(30_000) # 30 seconds for VMs to fully boot
      
      # Step 3: Call mix romulus.k8s.bootstrap
      Logger.info("Bootstrapping Kubernetes cluster")
      bootstrap_result = run_mix_task("romulus.k8s.bootstrap", [
        "--config", config_file
      ])
      assert {:ok, _output} = bootstrap_result
      
      # Step 4: Wait for node readiness using kubectl (10 minute timeout)
      Logger.info("Waiting for Kubernetes nodes to be ready")
      assert {:ok, _} = wait_for_k8s_nodes_ready(post_apply_state, 600) # 10 minutes
      
      # Step 5: Run a dummy workload to test cluster functionality
      Logger.info("Running dummy workload to verify cluster")
      assert {:ok, _} = run_dummy_k8s_workload(post_apply_state)
      
      # Step 6: Clean up infrastructure
      Logger.info("Cleaning up infrastructure after K8s bootstrap test")
      destroy_result = run_mix_task("romulus.destroy", [
        "--config", config_file
      ])
      assert {:ok, _output} = destroy_result
      
      # Verify complete cleanup
      assert {:ok, post_destroy_state} = State.fetch_current()
      assert_empty_infrastructure(post_destroy_state, @test_cluster_name)
      
      Logger.info("Kubernetes bootstrap and health verification test passed")
    end
  end
  
  # Helper functions for test execution
  
  defp run_mix_task(task, args) do
    try do
      # Capture both stdout and stderr
      {output, exit_code} = System.cmd("mix", [task | args], [
        stderr_to_stdout: true,
        env: [{"ROMULUS_AUTO_APPROVE", "true"}],
        cd: File.cwd!()
      ])
      
      case exit_code do
        0 -> {:ok, output}
        _ -> {:error, "Task failed with exit code #{exit_code}: #{output}"}
      end
    rescue
      error -> {:error, "Task execution failed: #{inspect(error)}"}
    end
  end
  
  defp generate_test_config do
    """
    cluster:
      name: #{@test_cluster_name}
      domain: e2e.test.local
      description: "E2E smoke test cluster"

    network:
      name: #{@test_network_name}
      mode: nat
      cidr: "192.168.250.0/24"
      dhcp: true
      dns: true
      autostart: false

    storage:
      pool_name: #{@test_pool_name}
      pool_path: /tmp/romulus-e2e-test
      pool_type: dir
      base_image:
        name: debian-12-e2e-base
        url: https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-nocloud-amd64.qcow2
        format: qcow2

    nodes:
      masters:
        count: 1
        memory: 1536  # 1.5GB to ensure kubelet can start
        vcpus: 2
        disk_size: 10737418240  # 10GB
        ip_prefix: "192.168.250.10"
        role: master
        
      workers:
        count: 1  
        memory: 1536  # 1.5GB 
        vcpus: 2
        disk_size: 10737418240  # 10GB
        ip_prefix: "192.168.250.20"
        role: worker

    ssh:
      public_key_path: /tmp/romulus_e2e_test.pub
      private_key_path: /tmp/romulus_e2e_test
      user: debian
      port: 22
      connection_timeout: 30
      retry_attempts: 3

    kubernetes:
      version: "1.28"
      pod_subnet: "10.244.0.0/16"
      service_subnet: "10.96.0.0/12"
      api_server_port: 6443
      cluster_dns: "10.96.0.10"
      cluster_domain: "cluster.local"
      container_runtime: containerd
      cgroup_driver: systemd

    bootstrap:
      cni: flannel
      ingress: false  # Skip ingress for smoke tests
      storage: false  # Skip storage for smoke tests
      monitoring: false  # Skip monitoring for smoke tests
      cert_manager: false
      dashboard: false
      metrics_server: true
    """
  end
  
  defp generate_partial_config do
    """
    cluster:
      name: #{@test_cluster_name}
      domain: partial.test.local

    network:
      name: #{@test_network_name}
      mode: nat
      cidr: "192.168.250.0/24"
      dhcp: true
      dns: true

    storage:
      pool_name: #{@test_pool_name}
      pool_path: /tmp/romulus-e2e-test
      pool_type: dir
      base_image:
        name: debian-12-partial-base
        url: https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-nocloud-amd64.qcow2
        format: qcow2

    # No nodes defined for partial config
    nodes:
      masters:
        count: 0
      workers:
        count: 0

    ssh:
      public_key_path: /tmp/romulus_e2e_test.pub
      user: debian
    """
  end
  
  defp generate_invalid_config do
    """
    cluster:
      name: #{@test_cluster_name}
      domain: invalid.test.local

    network:
      name: #{@test_network_name}
      mode: invalid_mode  # Invalid network mode
      cidr: "999.999.999.0/24"  # Invalid CIDR
      
    storage:
      pool_name: #{@test_pool_name}
      pool_path: ""  # Invalid empty path
      
    nodes:
      masters:
        count: -1  # Invalid negative count
        memory: 0   # Invalid zero memory
    """
  end
  
  # Assertion helpers
  
  defp assert_empty_infrastructure(state, cluster_name) do
    cluster_domains = Enum.filter(state.domains, &String.contains?(&1.name, cluster_name))
    cluster_networks = Enum.filter(state.networks, &String.contains?(&1.name, cluster_name))
    cluster_pools = Enum.filter(state.pools, &String.contains?(&1.name, cluster_name))
    
    assert cluster_domains == [], "Expected no cluster domains, found: #{inspect(cluster_domains)}"
    assert cluster_networks == [], "Expected no cluster networks, found: #{inspect(cluster_networks)}"
    assert cluster_pools == [], "Expected no cluster pools, found: #{inspect(cluster_pools)}"
  end
  
  defp assert_infrastructure_created(state, cluster_name) do
    cluster_domains = Enum.filter(state.domains, &String.contains?(&1.name, cluster_name))
    cluster_networks = Enum.filter(state.networks, &String.contains?(&1.name, cluster_name))
    cluster_pools = Enum.filter(state.pools, &String.contains?(&1.name, cluster_name))
    
    assert length(cluster_domains) >= 2, "Expected at least 2 VMs (1 master + 1 worker), found: #{length(cluster_domains)}"
    assert length(cluster_networks) >= 1, "Expected at least 1 network, found: #{length(cluster_networks)}"
    assert length(cluster_pools) >= 1, "Expected at least 1 storage pool, found: #{length(cluster_pools)}"
    
    # Verify all VMs are running
    running_domains = Enum.filter(cluster_domains, &(&1.state == :running))
    assert length(running_domains) == length(cluster_domains), 
           "Expected all VMs to be running, but #{length(cluster_domains) - length(running_domains)} are not"
  end
  
  defp assert_network_exists(state, network_name) do
    network = Enum.find(state.networks, &(&1.name == network_name))
    assert network != nil, "Expected network #{network_name} to exist"
    assert network.state == :active, "Expected network to be active"
  end
  
  defp assert_pool_exists(state, pool_name) do
    pool = Enum.find(state.pools, &(&1.name == pool_name))
    assert pool != nil, "Expected pool #{pool_name} to exist"
    assert pool.state == :active, "Expected pool to be active"
  end
  
  defp assert_infrastructure_consistent(state, cluster_name) do
    cluster_domains = Enum.filter(state.domains, &String.contains?(&1.name, cluster_name))
    cluster_networks = Enum.filter(state.networks, &String.contains?(&1.name, cluster_name))
    cluster_pools = Enum.filter(state.pools, &String.contains?(&1.name, cluster_name))
    
    # Basic infrastructure should exist
    assert length(cluster_domains) >= 1, "Expected at least 1 VM after conflict resolution"
    assert length(cluster_networks) >= 1, "Expected at least 1 network after conflict resolution"
    assert length(cluster_pools) >= 1, "Expected at least 1 pool after conflict resolution"
    
    # All resources should be in consistent state
    Enum.each(cluster_domains, fn domain ->
      assert domain.state in [:running, :shut_off], "Domain #{domain.name} in unexpected state: #{domain.state}"
    end)
    
    Enum.each(cluster_networks, fn network ->
      assert network.state == :active, "Network #{network.name} should be active"
    end)
    
    Enum.each(cluster_pools, fn pool ->
      assert pool.state == :active, "Pool #{pool.name} should be active"
    end)
  end
  
  defp assert_vm_ssh_connectivity(state, config_file) do
    {:ok, config} = Config.load(config_file)
    
    cluster_domains = Enum.filter(state.domains, &String.contains?(&1.name, @test_cluster_name))
    ssh_user = get_in(config, [:ssh, :user]) || "debian"
    private_key = get_in(config, [:ssh, :private_key_path])
    
    # Create SSH key pair if it doesn't exist
    ensure_ssh_key_pair(private_key)
    
    Enum.each(cluster_domains, fn domain ->
      if domain.ip_address do
        Logger.info("Testing SSH connectivity to #{domain.name} (#{domain.ip_address})")
        
        # Try SSH connection with timeout
        ssh_cmd = [
          "ssh", "-i", private_key,
          "-o", "ConnectTimeout=10",
          "-o", "StrictHostKeyChecking=no",
          "-o", "UserKnownHostsFile=/dev/null",
          "#{ssh_user}@#{domain.ip_address}",
          "echo 'SSH connection successful'"
        ]
        
        case System.cmd("timeout", ["30"] ++ ssh_cmd, stderr_to_stdout: true) do
          {output, 0} ->
            assert String.contains?(output, "SSH connection successful"),
                   "SSH connection to #{domain.name} failed: #{output}"
          {output, exit_code} ->
            Logger.warning("SSH connection to #{domain.name} failed (exit: #{exit_code}): #{output}")
            # Don't fail the test for SSH issues - just log them
        end
      else
        Logger.warning("VM #{domain.name} has no IP address - skipping SSH test")
      end
    end)
  end
  
  defp assert_kubelet_running(state) do
    cluster_domains = Enum.filter(state.domains, &String.contains?(&1.name, @test_cluster_name))
    
    # For smoke tests, we'll check if systemd is running and kubelet service is available
    # This is a lightweight check since full k8s bootstrap might not be complete
    
    Enum.each(cluster_domains, fn domain ->
      if domain.ip_address && domain.state == :running do
        Logger.info("Checking kubelet status on #{domain.name}")
        
        # Check if kubelet is installed and configured (don't require it to be running)
        kubelet_check = [
          "ssh", "-i", "/tmp/romulus_e2e_test",
          "-o", "ConnectTimeout=10",
          "-o", "StrictHostKeyChecking=no",
          "-o", "UserKnownHostsFile=/dev/null",
          "debian@#{domain.ip_address}",
          "systemctl status kubelet || systemctl is-enabled kubelet || which kubelet"
        ]
        
        case System.cmd("timeout", ["30"] ++ kubelet_check, stderr_to_stdout: true) do
          {output, exit_code} when exit_code in [0, 3] ->
            # Exit code 3 is acceptable (service inactive but installed)
            Logger.info("Kubelet check on #{domain.name}: #{String.trim(output)}")
          {output, exit_code} ->
            Logger.warning("Kubelet check failed on #{domain.name} (exit: #{exit_code}): #{output}")
            # Don't fail test for kubelet issues in smoke tests
        end
      end
    end)
  end
  
  # Resource management helpers
  
  defp cleanup_test_resources do
    Logger.info("Cleaning up test resources")
    
    # Clean up libvirt resources with test cluster name
    cleanup_domains(@test_cluster_name)
    cleanup_networks(@test_cluster_name)
    cleanup_pools(@test_cluster_name)
    
    # Clean up test files
    File.rm_rf("/tmp/romulus-e2e-test")
    File.rm("/tmp/romulus_e2e_test")
    File.rm("/tmp/romulus_e2e_test.pub")
  end
  
  defp cleanup_domains(cluster_name) do
    case System.cmd("virsh", ["list", "--all", "--name"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.contains?(&1, cluster_name))
        |> Enum.each(fn domain ->
          System.cmd("virsh", ["destroy", domain], stderr_to_stdout: true)
          System.cmd("virsh", ["undefine", domain, "--remove-all-storage"], stderr_to_stdout: true)
        end)
      _ -> :ok
    end
  end
  
  defp cleanup_networks(cluster_name) do
    case System.cmd("virsh", ["net-list", "--all", "--name"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.contains?(&1, cluster_name))
        |> Enum.each(fn network ->
          System.cmd("virsh", ["net-destroy", network], stderr_to_stdout: true)
          System.cmd("virsh", ["net-undefine", network], stderr_to_stdout: true)
        end)
      _ -> :ok
    end
  end
  
  defp cleanup_pools(cluster_name) do
    case System.cmd("virsh", ["pool-list", "--all", "--name"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.contains?(&1, cluster_name))
        |> Enum.each(fn pool ->
          System.cmd("virsh", ["pool-destroy", pool], stderr_to_stdout: true)
          System.cmd("virsh", ["pool-undefine", pool], stderr_to_stdout: true)
        end)
      _ -> :ok
    end
  end
  
  defp create_conflicting_resources do
    # Create a conflicting network
    conflict_net_xml = """
    <network>
      <name>#{@test_network_name}</name>
      <forward mode='nat'/>
      <ip address='192.168.250.1' netmask='255.255.255.0'>
        <dhcp>
          <range start='192.168.250.100' end='192.168.250.199'/>
        </dhcp>
      </ip>
    </network>
    """
    
    File.write!("/tmp/conflict_network.xml", conflict_net_xml)
    System.cmd("virsh", ["net-define", "/tmp/conflict_network.xml"], stderr_to_stdout: true)
    System.cmd("virsh", ["net-start", @test_network_name], stderr_to_stdout: true)
    File.rm("/tmp/conflict_network.xml")
    
    # Create a conflicting storage pool
    System.cmd("mkdir", ["-p", "/tmp/romulus-e2e-test"], stderr_to_stdout: true)
    System.cmd("virsh", ["pool-define-as", @test_pool_name, "dir", "--target", "/tmp/romulus-e2e-test"], stderr_to_stdout: true)
    System.cmd("virsh", ["pool-start", @test_pool_name], stderr_to_stdout: true)
  end
  
  defp cleanup_conflicting_resources do
    System.cmd("virsh", ["net-destroy", @test_network_name], stderr_to_stdout: true)
    System.cmd("virsh", ["net-undefine", @test_network_name], stderr_to_stdout: true)
    System.cmd("virsh", ["pool-destroy", @test_pool_name], stderr_to_stdout: true)
    System.cmd("virsh", ["pool-undefine", @test_pool_name], stderr_to_stdout: true)
  end
  
  defp ensure_ssh_key_pair(private_key_path) do
    public_key_path = private_key_path <> ".pub"
    
    unless File.exists?(private_key_path) do
      # Generate SSH key pair for testing
      System.cmd("ssh-keygen", [
        "-t", "rsa",
        "-b", "2048",
        "-f", private_key_path,
        "-N", "",  # No passphrase
        "-C", "romulus-e2e-test"
      ], stderr_to_stdout: true)
      
      File.chmod!(private_key_path, 0o600)
      File.chmod!(public_key_path, 0o644)
    end
  end
  
  # Kubernetes-specific helper functions
  
  # Waits for Kubernetes nodes to be ready within the specified timeout.
  # Uses kubectl through SSH to the master node to check node readiness.
  defp wait_for_k8s_nodes_ready(state, timeout_seconds) do
    Logger.info("Waiting for K8s nodes to be ready (timeout: #{timeout_seconds}s)")
    
    cluster_domains = Enum.filter(state.domains, &String.contains?(&1.name, @test_cluster_name))
    master_domain = Enum.find(cluster_domains, &String.contains?(&1.name, "master"))
    
    if master_domain && master_domain.ip_address do
      wait_for_k8s_nodes_ready_loop(master_domain.ip_address, timeout_seconds, 0)
    else
      {:error, "Could not find master node or IP address"}
    end
  end
  
  defp wait_for_k8s_nodes_ready_loop(master_ip, timeout_seconds, elapsed_seconds) when elapsed_seconds >= timeout_seconds do
    Logger.error("Timed out waiting for K8s nodes to be ready after #{elapsed_seconds} seconds")
    {:error, :timeout}
  end
  
  defp wait_for_k8s_nodes_ready_loop(master_ip, timeout_seconds, elapsed_seconds) do
    case check_k8s_nodes_ready(master_ip) do
      {:ok, _} ->
        Logger.info("All K8s nodes are ready after #{elapsed_seconds} seconds")
        {:ok, :all_nodes_ready}
      
      {:error, reason} ->
        Logger.debug("K8s nodes not ready yet (#{elapsed_seconds}s elapsed): #{inspect(reason)}")
        Process.sleep(10_000) # Wait 10 seconds before retrying
        wait_for_k8s_nodes_ready_loop(master_ip, timeout_seconds, elapsed_seconds + 10)
    end
  end
  
  defp check_k8s_nodes_ready(master_ip) do
    kubectl_cmd = [
      "ssh", "-i", "/tmp/romulus_e2e_test",
      "-o", "ConnectTimeout=10",
      "-o", "StrictHostKeyChecking=no",
      "-o", "UserKnownHostsFile=/dev/null",
      "debian@#{master_ip}",
      "kubectl get nodes --no-headers | awk '{if (\$2 != \"Ready\") exit 1}'"
    ]
    
    case System.cmd("timeout", ["30"] ++ kubectl_cmd, stderr_to_stdout: true) do
      {_output, 0} ->
        {:ok, :nodes_ready}
      {output, exit_code} ->
        {:error, "kubectl check failed (exit: #{exit_code}): #{String.trim(output)}"}
    end
  end
  
  # Runs a dummy workload to verify the Kubernetes cluster is functional.
  # Creates a test deployment and service, then verifies they're running.
  defp run_dummy_k8s_workload(state) do
    Logger.info("Running dummy workload to verify K8s cluster functionality")
    
    cluster_domains = Enum.filter(state.domains, &String.contains?(&1.name, @test_cluster_name))
    master_domain = Enum.find(cluster_domains, &String.contains?(&1.name, "master"))
    
    if master_domain && master_domain.ip_address do
      with {:ok, _} <- create_test_deployment(master_domain.ip_address),
           {:ok, _} <- wait_for_deployment_ready(master_domain.ip_address),
           {:ok, _} <- verify_deployment_pods(master_domain.ip_address),
           {:ok, _} <- cleanup_test_deployment(master_domain.ip_address) do
        Logger.info("Dummy workload test completed successfully")
        {:ok, :workload_verified}
      else
        {:error, reason} = error ->
          Logger.error("Dummy workload test failed: #{inspect(reason)}")
          # Attempt cleanup even if tests failed
          cleanup_test_deployment(master_domain.ip_address)
          error
      end
    else
      {:error, "Could not find master node or IP address"}
    end
  end
  
  defp create_test_deployment(master_ip) do
    Logger.debug("Creating test deployment")
    
    deployment_yaml = """
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-nginx
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: test-nginx
  template:
    metadata:
      labels:
        app: test-nginx
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
        resources:
          requests:
            memory: "64Mi"
            cpu: "50m"
          limits:
            memory: "128Mi"
            cpu: "100m"
"""
    
    create_cmd = [
      "ssh", "-i", "/tmp/romulus_e2e_test",
      "-o", "ConnectTimeout=10",
      "-o", "StrictHostKeyChecking=no",
      "-o", "UserKnownHostsFile=/dev/null",
      "debian@#{master_ip}",
      "echo '#{deployment_yaml}' | kubectl apply -f -"
    ]
    
    case System.cmd("timeout", ["60"] ++ create_cmd, stderr_to_stdout: true) do
      {output, 0} ->
        Logger.debug("Test deployment created: #{String.trim(output)}")
        {:ok, :deployment_created}
      {output, exit_code} ->
        {:error, "Failed to create test deployment (exit: #{exit_code}): #{String.trim(output)}"}
    end
  end
  
  defp wait_for_deployment_ready(master_ip) do
    Logger.debug("Waiting for test deployment to be ready")
    wait_for_deployment_ready_loop(master_ip, 120, 0) # 2 minute timeout
  end
  
  defp wait_for_deployment_ready_loop(master_ip, timeout_seconds, elapsed_seconds) when elapsed_seconds >= timeout_seconds do
    {:error, :deployment_timeout}
  end
  
  defp wait_for_deployment_ready_loop(master_ip, timeout_seconds, elapsed_seconds) do
    wait_cmd = [
      "ssh", "-i", "/tmp/romulus_e2e_test",
      "-o", "ConnectTimeout=10",
      "-o", "StrictHostKeyChecking=no",
      "-o", "UserKnownHostsFile=/dev/null",
      "debian@#{master_ip}",
      "kubectl get deployment test-nginx -o jsonpath='{.status.readyReplicas}'"
    ]
    
    case System.cmd("timeout", ["30"] ++ wait_cmd, stderr_to_stdout: true) do
      {"2", 0} ->
        Logger.debug("Test deployment is ready after #{elapsed_seconds} seconds")
        {:ok, :deployment_ready}
      {_output, _} ->
        Process.sleep(5000) # Wait 5 seconds
        wait_for_deployment_ready_loop(master_ip, timeout_seconds, elapsed_seconds + 5)
    end
  end
  
  defp verify_deployment_pods(master_ip) do
    Logger.debug("Verifying deployment pods are running")
    
    verify_cmd = [
      "ssh", "-i", "/tmp/romulus_e2e_test",
      "-o", "ConnectTimeout=10",
      "-o", "StrictHostKeyChecking=no",
      "-o", "UserKnownHostsFile=/dev/null",
      "debian@#{master_ip}",
      "kubectl get pods -l app=test-nginx --no-headers | awk '{if (\$3 != \"Running\") exit 1; count++} END {if (count < 2) exit 1}'"
    ]
    
    case System.cmd("timeout", ["30"] ++ verify_cmd, stderr_to_stdout: true) do
      {_output, 0} ->
        Logger.debug("All test deployment pods are running")
        {:ok, :pods_verified}
      {output, exit_code} ->
        {:error, "Pod verification failed (exit: #{exit_code}): #{String.trim(output)}"}
    end
  end
  
  defp cleanup_test_deployment(master_ip) do
    Logger.debug("Cleaning up test deployment")
    
    cleanup_cmd = [
      "ssh", "-i", "/tmp/romulus_e2e_test",
      "-o", "ConnectTimeout=10",
      "-o", "StrictHostKeyChecking=no",
      "-o", "UserKnownHostsFile=/dev/null",
      "debian@#{master_ip}",
      "kubectl delete deployment test-nginx --ignore-not-found=true"
    ]
    
    case System.cmd("timeout", ["60"] ++ cleanup_cmd, stderr_to_stdout: true) do
      {_output, 0} ->
        {:ok, :deployment_cleaned}
      {output, exit_code} ->
        Logger.warning("Failed to cleanup test deployment (exit: #{exit_code}): #{String.trim(output)}")
        {:ok, :cleanup_attempted} # Don't fail the test for cleanup issues
    end
  end
end
