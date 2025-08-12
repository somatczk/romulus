defmodule Romulus.State.Schema do
  @moduledoc """
  Configuration schema and state models for Romulus infrastructure.
  Defines native Elixir structures for libvirt resource management.
  """

  defmodule VM do
    @moduledoc "Virtual Machine configuration"
    defstruct [:name, :type, :memory, :vcpu, :disk_size, :ip, :pool, :network]

    @type t :: %__MODULE__{
            name: String.t(),
            type: :master | :worker,
            memory: integer(),
            vcpu: integer(),
            disk_size: integer(),
            ip: String.t(),
            pool: String.t(),
            network: String.t()
          }
  end

  defmodule Network do
    @moduledoc "Network configuration"
    defstruct [:name, :mode, :domain, :addresses, :dns_enabled, :dhcp_enabled]

    @type t :: %__MODULE__{
            name: String.t(),
            mode: String.t(),
            domain: String.t(),
            addresses: [String.t()],
            dns_enabled: boolean(),
            dhcp_enabled: boolean()
          }
  end

  defmodule Pool do
    @moduledoc "Storage pool configuration"
    defstruct [:name, :type, :path]

    @type t :: %__MODULE__{
            name: String.t(),
            type: String.t(),
            path: String.t()
          }
  end

  defmodule Volume do
    @moduledoc "Storage volume configuration"
    defstruct [:name, :pool, :size, :format, :base_volume, :source]

    @type t :: %__MODULE__{
            name: String.t(),
            pool: String.t(),
            size: integer(),
            format: String.t(),
            base_volume: String.t() | nil,
            source: String.t() | nil
          }
  end

  defmodule CloudInit do
    @moduledoc "Cloud-init configuration"
    defstruct [:hostname, :ssh_key, :node_ip, :user_data, :network_config]

    @type t :: %__MODULE__{
            hostname: String.t(),
            ssh_key: String.t(),
            node_ip: String.t(),
            user_data: String.t(),
            network_config: String.t()
          }
  end

  defmodule ClusterConfig do
    @moduledoc "Complete cluster configuration"
    defstruct [
      :master_count,
      :worker_count,
      :master_memory,
      :worker_memory,
      :master_vcpu,
      :worker_vcpu,
      :master_disk_size,
      :worker_disk_size,
      :ssh_public_key_path,
      :base_image_url,
      :network_cidr,
      :pool_path
    ]

    @type t :: %__MODULE__{
            master_count: integer(),
            worker_count: integer(),
            master_memory: integer(),
            worker_memory: integer(),
            master_vcpu: integer(),
            worker_vcpu: integer(),
            master_disk_size: integer(),
            worker_disk_size: integer(),
            ssh_public_key_path: String.t(),
            base_image_url: String.t(),
            network_cidr: String.t(),
            pool_path: String.t()
          }

    @doc "Default configuration for Kubernetes cluster"
    def default do
      %__MODULE__{
        master_count: 2,
        worker_count: 3,
        master_memory: 1024,
        worker_memory: 18432,
        master_vcpu: 1,
        worker_vcpu: 6,
        master_disk_size: 53_687_091_200,
        worker_disk_size: 107_374_182_400,
        ssh_public_key_path: "/etc/ssh/ssh_host_rsa_key.pub",
        base_image_url:
          "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-nocloud-amd64.qcow2",
        network_cidr: "10.10.10.0/24",
        pool_path: "/var/lib/libvirt/images/k8s-cluster"
      }
    end
  end

  @doc """
  Validates configuration using NimbleOptions schema validation.
  Ensures all required fields are present and have correct types.
  """
  def validate_config(config) do
    schema = [
      master_count: [
        type: :non_neg_integer,
        required: true,
        doc: "Number of master nodes"
      ],
      worker_count: [
        type: :non_neg_integer,
        required: true,
        doc: "Number of worker nodes"
      ],
      master_memory: [
        type: :non_neg_integer,
        required: true,
        doc: "Memory for master nodes in MB"
      ],
      worker_memory: [
        type: :non_neg_integer,
        required: true,
        doc: "Memory for worker nodes in MB"
      ],
      master_vcpu: [
        type: :non_neg_integer,
        required: true,
        doc: "vCPUs for master nodes"
      ],
      worker_vcpu: [
        type: :non_neg_integer,
        required: true,
        doc: "vCPUs for worker nodes"
      ],
      master_disk_size: [
        type: :non_neg_integer,
        required: true,
        doc: "Disk size for master nodes in bytes"
      ],
      worker_disk_size: [
        type: :non_neg_integer,
        required: true,
        doc: "Disk size for worker nodes in bytes"
      ],
      ssh_public_key_path: [
        type: :string,
        required: true,
        doc: "Path to SSH public key"
      ],
      base_image_url: [
        type: :string,
        required: true,
        doc: "URL of the base VM image"
      ],
      network_cidr: [
        type: :string,
        required: false,
        default: "10.10.10.0/24",
        doc: "Network CIDR block"
      ],
      pool_path: [
        type: :string,
        required: false,
        default: "/var/lib/libvirt/images/k8s-cluster",
        doc: "Storage pool path"
      ]
    ]

    NimbleOptions.validate(config, schema)
  end
end