defmodule RomulusElixir.State do
  @moduledoc """
  State management for infrastructure resources.
  Represents both current and desired states.
  """
  
  alias RomulusElixir.Libvirt
  
  defstruct [
    :networks,
    :pools,
    :volumes,
    :domains,
    :timestamp
  ]
  
  @doc """
  Create an empty state.
  """
  def empty do
    %__MODULE__{
      networks: [],
      pools: [],
      volumes: [],
      domains: [],
      timestamp: DateTime.utc_now()
    }
  end
  
  @doc """
  Fetch the current state from libvirt.
  """
  def fetch_current do
    with {:ok, networks} <- Libvirt.list_networks(),
         {:ok, pools} <- Libvirt.list_pools(),
         {:ok, volumes} <- Libvirt.list_volumes(),
         {:ok, domains} <- Libvirt.list_domains() do
      {:ok, %__MODULE__{
        networks: networks,
        pools: pools,
        volumes: volumes,
        domains: domains,
        timestamp: DateTime.utc_now()
      }}
    end
  end
  
  @doc """
  Generate desired state from configuration.
  """
  def from_config(config) do
    state = %__MODULE__{
      networks: build_networks(config),
      pools: build_pools(config),
      volumes: build_volumes(config),
      domains: build_domains(config),
      timestamp: DateTime.utc_now()
    }
    
    {:ok, state}
  end
  
  defp build_networks(config) do
    network = config[:network]
    
    [
      %Libvirt.Network{
        name: network[:name],
        mode: network[:mode],
        domain: config[:cluster][:domain],
        addresses: [network[:cidr]],
        dhcp: network[:dhcp],
        dns: network[:dns]
      }
    ]
  end
  
  defp build_pools(config) do
    storage = config[:storage]
    
    [
      %Libvirt.Pool{
        name: storage[:pool_name],
        type: "dir",
        path: storage[:pool_path]
      }
    ]
  end
  
  defp build_volumes(config) do
    storage = config[:storage]
    nodes = config[:nodes]
    
    base_volume = %Libvirt.Volume{
      name: storage[:base_image][:name],
      pool: storage[:pool_name],
      source: storage[:base_image][:url],
      format: storage[:base_image][:format]
    }
    
    master_volumes = for i <- 1..nodes[:masters][:count] do
      %Libvirt.Volume{
        name: "k8s-master-#{i}-disk",
        pool: storage[:pool_name],
        base_volume: storage[:base_image][:name],
        size: nodes[:masters][:disk_size]
      }
    end
    
    worker_volumes = for i <- 1..nodes[:workers][:count] do
      %Libvirt.Volume{
        name: "k8s-worker-#{i}-disk",
        pool: storage[:pool_name],
        base_volume: storage[:base_image][:name],
        size: nodes[:workers][:disk_size]
      }
    end
    
    master_cloudinit = for i <- 1..nodes[:masters][:count] do
      %Libvirt.Volume{
        name: "k8s-master-#{i}-init.iso",
        pool: storage[:pool_name],
        type: :cloudinit,
        node_type: :master,
        node_index: i
      }
    end
    
    worker_cloudinit = for i <- 1..nodes[:workers][:count] do
      %Libvirt.Volume{
        name: "k8s-worker-#{i}-init.iso",
        pool: storage[:pool_name],
        type: :cloudinit,
        node_type: :worker,
        node_index: i
      }
    end
    
    [base_volume] ++ master_volumes ++ worker_volumes ++ master_cloudinit ++ worker_cloudinit
  end
  
  defp build_domains(config) do
    nodes = config[:nodes]
    network = config[:network]
    storage = config[:storage]
    
    masters = for i <- 1..nodes[:masters][:count] do
      %Libvirt.Domain{
        name: "k8s-master-#{i}",
        memory: nodes[:masters][:memory],
        vcpu: nodes[:masters][:vcpus],
        network: network[:name],
        disk_volume: "k8s-master-#{i}-disk",
        cloudinit_volume: "k8s-master-#{i}-init.iso",
        pool: storage[:pool_name],
        ip_address: "#{nodes[:masters][:ip_prefix]}#{i}"
      }
    end
    
    workers = for i <- 1..nodes[:workers][:count] do
      %Libvirt.Domain{
        name: "k8s-worker-#{i}",
        memory: nodes[:workers][:memory],
        vcpu: nodes[:workers][:vcpus],
        network: network[:name],
        disk_volume: "k8s-worker-#{i}-disk",
        cloudinit_volume: "k8s-worker-#{i}-init.iso",
        pool: storage[:pool_name],
        ip_address: "#{nodes[:workers][:ip_prefix]}#{i}"
      }
    end
    
    masters ++ workers
  end
end