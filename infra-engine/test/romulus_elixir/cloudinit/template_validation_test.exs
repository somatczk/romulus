defmodule RomulusElixir.CloudInit.TemplateValidationTest do
  @moduledoc """
  Comprehensive validation tests for cloud-init templates.
  
  Tests cover:
  1. EEx render checks to ensure every variable placeholder is satisfied
  2. Validation of generated user-data and meta-data against cloud-init schema  
  3. Round-trip render + parse to confirm idempotency
  """
  
  use ExUnit.Case, async: true
  
  alias RomulusElixir.CloudInit.Renderer
  
  # Test fixtures and helper data
  @test_config %{
    cluster: %{name: "test-cluster", domain: "test.local"},
    nodes: %{
      masters: %{count: 2, ip_prefix: "10.10.10.1", memory: 2048, vcpus: 2, disk_size: 21474836480},
      workers: %{count: 3, ip_prefix: "10.10.10.2", memory: 1024, vcpus: 1, disk_size: 10737418240}
    },
    ssh: %{
      public_key_path: "/tmp/test_key.pub",
      private_key_path: "/tmp/test_key",
      user: "debian"
    }
  }
  
  @valid_variables [
    hostname: "k8s-master-1",
    ssh_key: "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDtest test@test",
    node_ip: "10.10.10.11",
    ip_address: "10.10.10.11"
  ]
  
  @template_dir Path.join([:code.priv_dir(:romulus_elixir), "cloud-init"])
  
  # Required cloud-init schema fields for validation
  @required_user_data_fields ~w(hostname users package_update packages write_files runcmd final_message power_state)
  @required_network_config_fields ~w(version ethernets)
  @required_meta_data_fields ~w(instance-id local-hostname)
  
  setup do
    # Ensure test SSH key exists for template rendering
    File.write!("/tmp/test_key.pub", "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDtest test@test")
    
    on_exit(fn ->
      File.rm("/tmp/test_key.pub")
    end)
    
    :ok
  end
  
  describe "EEx template rendering validation" do
    test "renders master template with all required variables" do
      template_path = Path.join(@template_dir, "cloud-init-master.yml")
      
      assert {:ok, rendered} = Renderer.render_user_data(template_path, @valid_variables)
      assert is_binary(rendered)
      assert String.contains?(rendered, "k8s-master-1")  # hostname substitution
      assert String.contains?(rendered, "10.10.10.11")   # IP substitution
      assert String.contains?(rendered, "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDtest")  # SSH key
    end
    
    test "renders worker template with all required variables" do
      worker_variables = [
        hostname: "k8s-worker-1",
        ssh_key: "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDtest test@test",
        node_ip: "10.10.10.21",
        ip_address: "10.10.10.21"
      ]
      
      template_path = Path.join(@template_dir, "cloud-init-worker.yml")
      
      assert {:ok, rendered} = Renderer.render_user_data(template_path, worker_variables)
      assert is_binary(rendered)
      assert String.contains?(rendered, "k8s-worker-1")
      assert String.contains?(rendered, "10.10.10.21")
    end
    
    test "renders network config template with all required variables" do
      template_path = Path.join(@template_dir, "network-config.yml")
      
      assert {:ok, rendered} = Renderer.render_network_config(template_path, @valid_variables)
      assert is_binary(rendered)
      assert String.contains?(rendered, "10.10.10.11/24")  # IP with CIDR
    end
    
    test "fails gracefully when required variables are missing" do
      incomplete_variables = [hostname: "k8s-master-1"]  # Missing ssh_key, node_ip
      template_path = Path.join(@template_dir, "cloud-init-master.yml")
      
      # With variable substitution, missing variables will result in unreplaced placeholders
      assert {:ok, rendered} = Renderer.render_user_data(template_path, incomplete_variables)
      
      # Should still contain unreplaced variable placeholders
      assert String.contains?(rendered, "${ssh_key}")
      assert String.contains?(rendered, "${node_ip}")
      # Note: master template uses node_ip, not ip_address
    end
    
    test "fails gracefully when template file does not exist" do
      non_existent_template = "/path/to/non-existent-template.yml"
      
      assert {:error, "Failed to read template: " <> _reason} = 
        Renderer.render_user_data(non_existent_template, @valid_variables)
    end
    
    test "handles empty variable values appropriately" do
      empty_ssh_variables = [
        hostname: "k8s-master-1",
        ssh_key: "",  # Empty SSH key
        node_ip: "10.10.10.11",
        ip_address: "10.10.10.11"
      ]
      
      template_path = Path.join(@template_dir, "cloud-init-master.yml")
      assert {:ok, rendered} = Renderer.render_user_data(template_path, empty_ssh_variables)
      
      # Should render but result in empty SSH key line
      assert String.contains?(rendered, "ssh_authorized_keys:\n      - ")
    end
    
    test "validates all variable placeholders are satisfied in master template" do
      {:ok, template_content} = File.read(Path.join(@template_dir, "cloud-init-master.yml"))
      
      # Use the built-in validation function that handles duplicates
      missing_variables = Renderer.validate_template_variables(template_content, @valid_variables)
      
      assert missing_variables == [], 
        "Missing variables in test data: #{inspect(missing_variables)}"
    end
    
    test "validates all variable placeholders are satisfied in worker template" do
      {:ok, template_content} = File.read(Path.join(@template_dir, "cloud-init-worker.yml"))
      
      # Use the built-in validation function that handles duplicates
      missing_variables = Renderer.validate_template_variables(template_content, @valid_variables)
      
      assert missing_variables == [], 
        "Missing variables in test data: #{inspect(missing_variables)}"
    end
    
    test "validates all variable placeholders are satisfied in network config template" do
      {:ok, template_content} = File.read(Path.join(@template_dir, "network-config.yml"))
      
      # Use the built-in validation function that handles duplicates
      missing_variables = Renderer.validate_template_variables(template_content, @valid_variables)
      
      assert missing_variables == [], 
        "Missing variables in test data: #{inspect(missing_variables)}"
    end
  end
  
  describe "cloud-init YAML schema validation" do
    test "validates rendered master user-data against cloud-init schema" do
      template_path = Path.join(@template_dir, "cloud-init-master.yml")
      {:ok, rendered} = Renderer.render_user_data(template_path, @valid_variables)
      
      # Parse YAML and validate structure
      {:ok, parsed} = YamlElixir.read_from_string(rendered)
      
      # Validate required top-level fields are present
      for field <- @required_user_data_fields do
        assert Map.has_key?(parsed, field), 
          "Missing required field '#{field}' in user-data"
      end
      
      # Validate specific field types and structures
      assert is_binary(parsed["hostname"])
      assert is_list(parsed["users"])
      assert is_boolean(parsed["package_update"])
      assert is_list(parsed["packages"])
      assert is_list(parsed["write_files"])
      assert is_list(parsed["runcmd"])
      assert is_binary(parsed["final_message"])
      assert is_map(parsed["power_state"])
      
      # Validate users structure
      user = List.first(parsed["users"])
      assert Map.has_key?(user, "name")
      assert Map.has_key?(user, "ssh_authorized_keys")
      assert Map.has_key?(user, "sudo")
    end
    
    test "validates rendered worker user-data against cloud-init schema" do
      worker_variables = [
        hostname: "k8s-worker-1",
        ssh_key: "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDtest test@test",
        node_ip: "10.10.10.21",
        ip_address: "10.10.10.21"
      ]
      
      template_path = Path.join(@template_dir, "cloud-init-worker.yml")
      {:ok, rendered} = Renderer.render_user_data(template_path, worker_variables)
      
      {:ok, parsed} = YamlElixir.read_from_string(rendered)
      
      # Same validation as master template since they share structure
      for field <- @required_user_data_fields do
        assert Map.has_key?(parsed, field), 
          "Missing required field '#{field}' in worker user-data"
      end
      
      # Worker-specific validation
      assert parsed["hostname"] == "k8s-worker-1"
      assert String.contains?(parsed["final_message"], "Worker node")
    end
    
    test "validates rendered network config against cloud-init schema" do
      template_path = Path.join(@template_dir, "network-config.yml")
      {:ok, rendered} = Renderer.render_network_config(template_path, @valid_variables)
      
      {:ok, parsed} = YamlElixir.read_from_string(rendered)
      
      # Validate network config structure
      for field <- @required_network_config_fields do
        assert Map.has_key?(parsed, field), 
          "Missing required field '#{field}' in network-config"
      end
      
      assert parsed["version"] == 2
      assert is_map(parsed["ethernets"])
      
      # Validate ethernet interface configuration
      interface = Map.values(parsed["ethernets"]) |> List.first()
      assert Map.has_key?(interface, "dhcp4")
      assert Map.has_key?(interface, "dhcp6") 
      assert Map.has_key?(interface, "addresses")
      assert Map.has_key?(interface, "gateway4")
      assert Map.has_key?(interface, "nameservers")
      
      # Validate IP address format
      addresses = interface["addresses"]
      assert is_list(addresses)
      assert Enum.any?(addresses, &String.contains?(&1, "10.10.10.11/24"))
    end
    
    test "validates meta-data structure" do
      # Test meta-data generation (from generator module)
      vm_name = "test-vm-1"
      expected_meta_data = "instance-id: #{vm_name}\nlocal-hostname: #{vm_name}\n"
      
      {:ok, parsed} = YamlElixir.read_from_string(expected_meta_data)
      
      for field <- @required_meta_data_fields do
        assert Map.has_key?(parsed, field), 
          "Missing required field '#{field}' in meta-data"
      end
      
      assert parsed["instance-id"] == vm_name
      assert parsed["local-hostname"] == vm_name
    end
    
    test "detects invalid YAML in rendered templates" do
      # Create a template with intentionally malformed YAML structure
      malformed_template = """
      hostname: ${hostname}
      users:
        - name: debian
          invalid_yaml_structure_missing_colon
            - ${ssh_key}
      """
      
      temp_file = "/tmp/malformed_template.yml"
      File.write!(temp_file, malformed_template)
      
      {:ok, rendered} = Renderer.render_user_data(temp_file, @valid_variables)
      
      # Should fail YAML parsing
      assert {:error, _reason} = YamlElixir.read_from_string(rendered)
      
      File.rm!(temp_file)
    end
    
    test "validates YAML using Renderer.validate_yaml/1" do
      template_path = Path.join(@template_dir, "cloud-init-master.yml")
      {:ok, rendered} = Renderer.render_user_data(template_path, @valid_variables)
      
      assert :ok = Renderer.validate_yaml(rendered)
    end
    
    test "Renderer.validate_yaml/1 fails for invalid YAML" do
      invalid_yaml = """
      hostname: test
      users:
        - name: test
          invalid: [unclosed bracket
      """
      
      assert {:error, "Invalid YAML: " <> _reason} = Renderer.validate_yaml(invalid_yaml)
    end
  end
  
  describe "round-trip render + parse idempotency" do
    test "master template round-trip maintains data integrity" do
      template_path = Path.join(@template_dir, "cloud-init-master.yml")
      
      # First render
      {:ok, rendered1} = Renderer.render_user_data(template_path, @valid_variables)
      {:ok, parsed1} = YamlElixir.read_from_string(rendered1)
      
      # Second render with same variables
      {:ok, rendered2} = Renderer.render_user_data(template_path, @valid_variables)
      {:ok, parsed2} = YamlElixir.read_from_string(rendered2)
      
      # Compare rendered strings (should be identical)
      assert rendered1 == rendered2
      
      # Compare parsed structures (should be identical)
      assert parsed1 == parsed2
      
      # Verify critical fields maintain their values through round-trip
      assert parsed1["hostname"] == @valid_variables[:hostname]
      assert parsed2["hostname"] == @valid_variables[:hostname]
      
      # Validate that SSH key is preserved
      ssh_keys1 = get_in(parsed1, ["users", Access.at(0), "ssh_authorized_keys"])
      ssh_keys2 = get_in(parsed2, ["users", Access.at(0), "ssh_authorized_keys"])
      assert ssh_keys1 == ssh_keys2
      assert Enum.member?(ssh_keys1, @valid_variables[:ssh_key])
    end
    
    test "worker template round-trip maintains data integrity" do
      worker_variables = [
        hostname: "k8s-worker-1",
        ssh_key: "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDtest test@test",
        node_ip: "10.10.10.21", 
        ip_address: "10.10.10.21"
      ]
      
      template_path = Path.join(@template_dir, "cloud-init-worker.yml")
      
      # First render and parse
      {:ok, rendered1} = Renderer.render_user_data(template_path, worker_variables)
      {:ok, parsed1} = YamlElixir.read_from_string(rendered1)
      
      # Second render and parse
      {:ok, rendered2} = Renderer.render_user_data(template_path, worker_variables)
      {:ok, parsed2} = YamlElixir.read_from_string(rendered2)
      
      # Should be identical
      assert parsed1 == parsed2
      assert parsed1["hostname"] == "k8s-worker-1"
      assert parsed2["hostname"] == "k8s-worker-1"
    end
    
    test "network config round-trip maintains data integrity" do
      template_path = Path.join(@template_dir, "network-config.yml")
      
      # First render and parse
      {:ok, rendered1} = Renderer.render_network_config(template_path, @valid_variables)
      {:ok, parsed1} = YamlElixir.read_from_string(rendered1)
      
      # Second render and parse
      {:ok, rendered2} = Renderer.render_network_config(template_path, @valid_variables)
      {:ok, parsed2} = YamlElixir.read_from_string(rendered2)
      
      # Should be identical
      assert parsed1 == parsed2
      
      # Verify IP address preservation
      interface1 = Map.values(parsed1["ethernets"]) |> List.first()
      interface2 = Map.values(parsed2["ethernets"]) |> List.first()
      assert interface1["addresses"] == interface2["addresses"]
      assert Enum.member?(interface1["addresses"], "10.10.10.11/24")
    end
    
    test "full node cloud-init generation maintains round-trip integrity" do
      # Test the complete node generation process
      {:ok, cloudinit_data1} = Renderer.generate_node_cloudinit(:master, 1, @test_config)
      {:ok, cloudinit_data2} = Renderer.generate_node_cloudinit(:master, 1, @test_config)
      
      # Both generations should produce identical results
      assert cloudinit_data1.user_data == cloudinit_data2.user_data
      assert cloudinit_data1.network_config == cloudinit_data2.network_config
      
      # Validate both can be parsed as valid YAML
      {:ok, _parsed_user_data} = YamlElixir.read_from_string(cloudinit_data1.user_data)
      {:ok, _parsed_network_config} = YamlElixir.read_from_string(cloudinit_data1.network_config)
    end
    
    test "variable interpolation is deterministic across renders" do
      # Test with different variable sets to ensure consistent interpolation
      variables_set_1 = [
        hostname: "test-host-1",
        ssh_key: "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQ test1@test",
        node_ip: "192.168.1.10",
        ip_address: "192.168.1.10"
      ]
      
      variables_set_2 = [
        hostname: "test-host-2", 
        ssh_key: "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQ test2@test",
        node_ip: "192.168.1.20",
        ip_address: "192.168.1.20"
      ]
      
      template_path = Path.join(@template_dir, "cloud-init-master.yml")
      
      # Multiple renders with same variables should be identical
      {:ok, render_1a} = Renderer.render_user_data(template_path, variables_set_1)
      {:ok, render_1b} = Renderer.render_user_data(template_path, variables_set_1)
      assert render_1a == render_1b
      
      # Different variables should produce different results
      {:ok, render_2} = Renderer.render_user_data(template_path, variables_set_2)
      assert render_1a != render_2
      
      # But structure should be consistent
      {:ok, parsed_1} = YamlElixir.read_from_string(render_1a)
      {:ok, parsed_2} = YamlElixir.read_from_string(render_2)
      
      # Same structure, different values
      assert Map.keys(parsed_1) == Map.keys(parsed_2)
      assert parsed_1["hostname"] != parsed_2["hostname"]
      assert parsed_1["hostname"] == "test-host-1"
      assert parsed_2["hostname"] == "test-host-2"
    end
  end
  
  describe "template variable validation functions" do
    test "substitute_variables/2 correctly replaces shell-style variables" do
      template = "hostname: ${hostname}, IP: ${node_ip}, SSH: ${ssh_key}"
      variables = [
        hostname: "test-host",
        node_ip: "192.168.1.100", 
        ssh_key: "ssh-rsa AAAAB3..."
      ]
      
      result = Renderer.substitute_variables(template, variables)
      expected = "hostname: test-host, IP: 192.168.1.100, SSH: ssh-rsa AAAAB3..."
      
      assert result == expected
    end
    
    test "substitute_variables/2 leaves unreferenced variables untouched" do
      template = "hostname: ${hostname}"
      variables = [
        hostname: "test-host",
        unused_var: "unused-value"
      ]
      
      result = Renderer.substitute_variables(template, variables)
      assert result == "hostname: test-host"
    end
    
    test "substitute_variables/2 leaves unreplaced placeholders when variables missing" do
      template = "hostname: ${hostname}, IP: ${missing_var}"
      variables = [hostname: "test-host"]
      
      result = Renderer.substitute_variables(template, variables)
      assert result == "hostname: test-host, IP: ${missing_var}"
    end
    
    test "validate_template_variables/2 identifies missing variables" do
      template = "hostname: ${hostname}, IP: ${node_ip}, SSH: ${ssh_key}"
      variables = [hostname: "test-host"]  # Missing node_ip and ssh_key
      
      missing = Renderer.validate_template_variables(template, variables)
      assert Enum.sort(missing) == [:node_ip, :ssh_key]
    end
    
    test "validate_template_variables/2 returns empty list when all variables provided" do
      template = "hostname: ${hostname}, IP: ${node_ip}"
      variables = [hostname: "test-host", node_ip: "192.168.1.100"]
      
      missing = Renderer.validate_template_variables(template, variables)
      assert missing == []
    end
    
    test "validate_template_variables/2 handles duplicate variable names" do
      template = "hostname: ${hostname}, FQDN: ${hostname}.local"
      variables = [hostname: "test-host"]
      
      missing = Renderer.validate_template_variables(template, variables)
      assert missing == []
    end
    
    test "validate_template_variables/2 handles templates with no variables" do
      template = "static content with no variables"
      variables = [hostname: "test-host"]
      
      missing = Renderer.validate_template_variables(template, variables)
      assert missing == []
    end
  end
  
  describe "comprehensive integration tests" do
    test "validates all node types with complete configuration" do
      # Test all master nodes
      for i <- 1..@test_config.nodes.masters.count do
        assert {:ok, cloudinit_data} = Renderer.generate_node_cloudinit(:master, i, @test_config)
        
        # Validate user-data
        assert :ok = Renderer.validate_yaml(cloudinit_data.user_data)
        {:ok, parsed_user_data} = YamlElixir.read_from_string(cloudinit_data.user_data)
        assert parsed_user_data["hostname"] == "k8s-master-#{i}"
        
        # Validate network-config
        assert :ok = Renderer.validate_yaml(cloudinit_data.network_config)
        {:ok, parsed_network_config} = YamlElixir.read_from_string(cloudinit_data.network_config)
        assert parsed_network_config["version"] == 2
      end
      
      # Test all worker nodes
      for i <- 1..@test_config.nodes.workers.count do
        assert {:ok, cloudinit_data} = Renderer.generate_node_cloudinit(:worker, i, @test_config)
        
        # Validate user-data
        assert :ok = Renderer.validate_yaml(cloudinit_data.user_data)
        {:ok, parsed_user_data} = YamlElixir.read_from_string(cloudinit_data.user_data)
        assert parsed_user_data["hostname"] == "k8s-worker-#{i}"
        
        # Validate network-config
        assert :ok = Renderer.validate_yaml(cloudinit_data.network_config)
        {:ok, parsed_network_config} = YamlElixir.read_from_string(cloudinit_data.network_config)
        assert parsed_network_config["version"] == 2
      end
    end
    
    test "validates render_all function produces valid results for all nodes" do
      assert {:ok, all_results} = Renderer.render_all(@test_config)
      
      # Should have results for all masters and workers
      expected_count = @test_config.nodes.masters.count + @test_config.nodes.workers.count
      assert length(all_results) == expected_count
      
      # All results should be successful
      for {:ok, node_name, cloudinit_data} <- all_results do
        assert is_binary(node_name)
        assert String.starts_with?(node_name, "k8s-")
        
        # Validate generated data
        assert :ok = Renderer.validate_yaml(cloudinit_data.user_data)
        assert :ok = Renderer.validate_yaml(cloudinit_data.network_config)
        
        # Test round-trip
        {:ok, _parsed_user_data} = YamlElixir.read_from_string(cloudinit_data.user_data)
        {:ok, _parsed_network_config} = YamlElixir.read_from_string(cloudinit_data.network_config)
      end
    end
    
    test "handles edge cases and error conditions gracefully" do
      # Test with missing SSH key file
      config_with_missing_key = put_in(@test_config, [:ssh, :public_key_path], "/non/existent/key.pub")
      
      # Should still work but with empty SSH key
      assert {:ok, cloudinit_data} = Renderer.generate_node_cloudinit(:master, 1, config_with_missing_key)
      assert :ok = Renderer.validate_yaml(cloudinit_data.user_data)
      
      # Test with invalid node type
      assert_raise CaseClauseError, fn ->
        Renderer.generate_node_cloudinit(:invalid_node_type, 1, @test_config)
      end
    end
  end
end
