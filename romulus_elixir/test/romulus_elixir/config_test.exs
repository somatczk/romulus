defmodule RomulusElixir.ConfigTest do
  use ExUnit.Case, async: true

  alias RomulusElixir.Config

  describe "load/1" do
    setup do
      config_dir = "test/fixtures/config"
      File.mkdir_p!(config_dir)
      
      on_exit(fn -> File.rm_rf!(config_dir) end)
      
      {:ok, config_dir: config_dir}
    end

    test "loads valid YAML configuration", %{config_dir: config_dir} do
      config_path = Path.join(config_dir, "valid.yaml")
      File.write!(config_path, """
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
        pool_name: default
        pool_path: /var/lib/libvirt/images
        base_image:
          name: ubuntu-20.04
          url: https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img
          format: qcow2
      nodes:
        masters:
          count: 1
          memory: 2048
          vcpus: 2
          disk_size: 21474836480
          ip_prefix: "192.168.100.1"
        workers:
          count: 2
          memory: 4096
          vcpus: 4
          disk_size: 42949672960
          ip_prefix: "192.168.100.2"
      ssh:
        public_key_path: ~/.ssh/id_rsa.pub
        private_key_path: ~/.ssh/id_rsa
        user: ubuntu
      """)

      assert {:ok, config} = Config.load(config_path)
      
      # Validate cluster config
      assert config[:cluster][:name] == "test-cluster"
      assert config[:cluster][:domain] == "test.local"
      
      # Validate network config
      assert config[:network][:name] == "test-network"
      assert config[:network][:mode] == "nat"
      assert config[:network][:cidr] == "192.168.100.0/24"
      assert config[:network][:dhcp] == true
      assert config[:network][:dns] == true
      
      # Validate storage config
      assert config[:storage][:pool_name] == "default"
      assert config[:storage][:base_image][:name] == "ubuntu-20.04"
      
      # Validate node config
      assert config[:nodes][:masters][:count] == 1
      assert config[:nodes][:workers][:count] == 2
      
      # Validate SSH config
      assert config[:ssh][:user] == "ubuntu"
    end

    test "returns error for missing file" do
      assert {:error, reason} = Config.load("nonexistent.yaml")
      assert reason =~ "not found"
    end

    test "returns error for invalid YAML", %{config_dir: config_dir} do
      config_path = Path.join(config_dir, "invalid.yaml")
      File.write!(config_path, "invalid: yaml: content: [")
      
      assert {:error, reason} = Config.load(config_path)
      assert reason =~ "Failed to parse"
    end

    test "returns error for incomplete configuration", %{config_dir: config_dir} do
      config_path = Path.join(config_dir, "incomplete.yaml")
      File.write!(config_path, "cluster:\n  name: test")
      
      assert {:error, reason} = Config.load(config_path)
      assert reason =~ "validation"
    end
  end

  describe "validate/1" do
    test "validates complete configuration" do
      config = [
        cluster: [name: "test", domain: "test.local"],
        network: [name: "net", mode: "nat", cidr: "192.168.1.0/24", dhcp: true, dns: true],
        storage: [
          pool_name: "default",
          pool_path: "/tmp",
          base_image: [name: "base", url: "http://test.com/img.qcow2", format: "qcow2"]
        ],
        nodes: [
          masters: [count: 1, memory: 1024, vcpus: 1, disk_size: 1073741824, ip_prefix: "192.168.1.10"],
          workers: [count: 1, memory: 2048, vcpus: 2, disk_size: 2147483648, ip_prefix: "192.168.1.20"]
        ],
        ssh: [public_key_path: "/tmp/key.pub", private_key_path: "/tmp/key", user: "test"]
      ]
      
      assert {:ok, ^config} = Config.validate(config)
    end

    test "rejects missing cluster config" do
      config = [network: [name: "test"]]
      assert {:error, reason} = Config.validate(config)
      assert reason =~ "cluster"
    end

    test "rejects missing network config" do
      config = [cluster: [name: "test", domain: "test.local"]]
      assert {:error, reason} = Config.validate(config)
      assert reason =~ "network"
    end

    test "rejects invalid node counts" do
      config = [
        cluster: [name: "test", domain: "test.local"],
        network: [name: "net", mode: "nat", cidr: "192.168.1.0/24"],
        nodes: [masters: [count: 0]]
      ]
      
      assert {:error, reason} = Config.validate(config)
      assert reason =~ "master node count"
    end

    test "validates IP prefix format" do
      config = [
        cluster: [name: "test", domain: "test.local"],
        network: [name: "net", mode: "nat", cidr: "192.168.1.0/24", dhcp: true],
        storage: [pool_name: "default", pool_path: "/tmp"],
        nodes: [
          masters: [count: 1, memory: 1024, vcpus: 1, disk_size: 1073741824, ip_prefix: "invalid-ip"],
          workers: [count: 1, memory: 1024, vcpus: 1, disk_size: 1073741824, ip_prefix: "192.168.1.20"]
        ],
        ssh: [public_key_path: "/tmp/key.pub", user: "test"]
      ]
      
      assert {:error, reason} = Config.validate(config)
      assert reason =~ "IP prefix"
    end

    test "validates memory and disk sizes" do
      config = [
        cluster: [name: "test", domain: "test.local"],
        network: [name: "net", mode: "nat", cidr: "192.168.1.0/24"],
        storage: [pool_name: "default", pool_path: "/tmp"],
        nodes: [
          masters: [count: 1, memory: 0, vcpus: 1, disk_size: 1073741824, ip_prefix: "192.168.1.10"]
        ],
        ssh: [public_key_path: "/tmp/key.pub", user: "test"]
      ]
      
      assert {:error, reason} = Config.validate(config)
      assert reason =~ "memory"
    end
  end

  describe "get_default_config_paths/0" do
    test "returns standard configuration paths" do
      paths = Config.get_default_config_paths()
      
      assert is_list(paths)
      assert length(paths) > 0
      assert Enum.all?(paths, &is_binary/1)
      assert Enum.any?(paths, &String.ends_with?(&1, "romulus.yaml"))
    end
  end

  describe "merge_configs/2" do
    test "merges two configurations with second taking precedence" do
      base = [
        cluster: [name: "base", domain: "base.local"],
        nodes: [masters: [count: 1, memory: 1024]]
      ]
      
      override = [
        cluster: [name: "override"],
        nodes: [masters: [memory: 2048]]
      ]
      
      merged = Config.merge_configs(base, override)
      
      assert merged[:cluster][:name] == "override"
      assert merged[:cluster][:domain] == "base.local"
      assert merged[:nodes][:masters][:count] == 1
      assert merged[:nodes][:masters][:memory] == 2048
    end

    test "handles nil values correctly" do
      base = [cluster: [name: "test"]]
      assert Config.merge_configs(base, nil) == base
      assert Config.merge_configs(nil, base) == base
    end
  end

  describe "expand_paths/1" do
    test "expands home directory paths" do
      config = [
        ssh: [
          public_key_path: "~/.ssh/id_rsa.pub",
          private_key_path: "~/.ssh/id_rsa"
        ]
      ]
      
      expanded = Config.expand_paths(config)
      
      refute expanded[:ssh][:public_key_path] =~ "~"
      refute expanded[:ssh][:private_key_path] =~ "~"
      assert expanded[:ssh][:public_key_path] =~ ".ssh/id_rsa.pub"
    end

    test "leaves absolute paths unchanged" do
      config = [
        storage: [pool_path: "/var/lib/libvirt/images"],
        ssh: [public_key_path: "/tmp/key.pub"]
      ]
      
      expanded = Config.expand_paths(config)
      
      assert expanded[:storage][:pool_path] == "/var/lib/libvirt/images"
      assert expanded[:ssh][:public_key_path] == "/tmp/key.pub"
    end
  end
end