defmodule Romulus.Core.State do
  @moduledoc """
  State management for infrastructure resources.
  Represents both current and desired states.
  """
  
  alias Romulus.Infra.Libvirt
  
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
         {:ok, volumes} <- fetch_all_volumes(pools),
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
    with {:ok, _validated} <- Romulus.Core.Config.validate(config) do
      state = %__MODULE__{
        networks: build_networks(config),
        pools: build_pools(config),
        volumes: build_volumes(config),
        domains: build_domains(config),
        timestamp: DateTime.utc_now()
      }
      
      {:ok, state}
    else
      {:error, reason} -> {:error, reason}
    end
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
    
    master_count = nodes[:masters][:count] || 0
    worker_count = nodes[:workers][:count] || 0
    
    master_volumes = if master_count > 0 do
      for i <- 1..master_count do
        %Libvirt.Volume{
          name: "k8s-master-#{i}-disk",
          pool: storage[:pool_name],
          base_volume: storage[:base_image][:name],
          size: nodes[:masters][:disk_size]
        }
      end
    else
      []
    end
    
    worker_volumes = if worker_count > 0 do
      for i <- 1..worker_count do
        %Libvirt.Volume{
          name: "k8s-worker-#{i}-disk",
          pool: storage[:pool_name],
          base_volume: storage[:base_image][:name],
          size: nodes[:workers][:disk_size]
        }
      end
    else
      []
    end
    
    master_cloudinit = if master_count > 0 do
      for i <- 1..master_count do
        %Libvirt.Volume{
          name: "k8s-master-#{i}-init.iso",
          pool: storage[:pool_name],
          type: :cloudinit,
          node_type: :master,
          node_index: i
        }
      end
    else
      []
    end
    
    worker_cloudinit = if worker_count > 0 do
      for i <- 1..worker_count do
        %Libvirt.Volume{
          name: "k8s-worker-#{i}-init.iso",
          pool: storage[:pool_name],
          type: :cloudinit,
          node_type: :worker,
          node_index: i
        }
      end
    else
      []
    end
    
    [base_volume] ++ master_volumes ++ worker_volumes ++ master_cloudinit ++ worker_cloudinit
  end
  
  defp build_domains(config) do
    nodes = config[:nodes]
    network = config[:network]
    storage = config[:storage]
    
    master_count = nodes[:masters][:count] || 0
    worker_count = nodes[:workers][:count] || 0
    
    masters = if master_count > 0 do
      for i <- 1..master_count do
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
    else
      []
    end
    
    workers = if worker_count > 0 do
      for i <- 1..worker_count do
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
    else
      []
    end
    
    masters ++ workers
  end
  
  @doc """
  Compute the difference between two states.
  """
  def diff(%__MODULE__{} = state1, %__MODULE__{} = state2) do
    %{
      networks: diff_resources(state1.networks, state2.networks),
      pools: diff_resources(state1.pools, state2.pools),
      volumes: diff_resources(state1.volumes, state2.volumes),
      domains: diff_resources(state1.domains, state2.domains),
      summary: generate_diff_summary(state1, state2)
    }
  end
  
  @doc """
  Validate state consistency (check resource references).
  """
  def validate_state(%__MODULE__{} = state) do
    with :ok <- validate_domain_network_references(state),
         :ok <- validate_domain_pool_references(state),
         :ok <- validate_volume_pool_references(state) do
      {:ok, state}
    end
  end
  
  @doc """
  Count resources by type.
  """
  def count_resources(%__MODULE__{} = state, resource_type) do
    case resource_type do
      :networks -> length(state.networks)
      :pools -> length(state.pools)
      :volumes -> length(state.volumes)
      :domains -> length(state.domains)
      _ -> 0
    end
  end
  
  @doc """
  Count active resources by type.
  """
  def count_active_resources(%__MODULE__{} = state, resource_type) do
    case resource_type do
      :networks -> Enum.count(state.networks, & &1.active)
      :pools -> Enum.count(state.pools, & &1.active)
      :domains -> Enum.count(state.domains, & &1.state == :running)
      _ -> 0
    end
  end
  
  @doc """
  Count running domains.
  """
  def count_running_domains(%__MODULE__{} = state) do
    Enum.count(state.domains, & &1.state == :running)
  end
  
  @doc """
  Get resource summary.
  """
  def get_resource_summary(%__MODULE__{} = state) do
    %{
      networks: %{
        total: count_resources(state, :networks),
        active: count_active_resources(state, :networks)
      },
      pools: %{
        total: count_resources(state, :pools),
        active: count_active_resources(state, :pools)
      },
      volumes: %{
        total: count_resources(state, :volumes)
      },
      domains: %{
        total: count_resources(state, :domains),
        running: count_running_domains(state),
        stopped: count_resources(state, :domains) - count_running_domains(state)
      }
    }
  end
  
  # Private helper functions
  
  defp fetch_all_volumes(pools) do
    volumes = 
      pools
      |> Enum.flat_map(fn pool ->
        case Libvirt.list_volumes(pool.name) do
          {:ok, volumes} -> volumes
          {:error, _} -> []
        end
      end)
    
    {:ok, volumes}
  end
  
  defp diff_resources(resources1, resources2) do
    names1 = MapSet.new(resources1, & &1.name)
    names2 = MapSet.new(resources2, & &1.name)
    
    %{
      added: MapSet.difference(names2, names1) |> MapSet.to_list(),
      removed: MapSet.difference(names1, names2) |> MapSet.to_list(),
      common: MapSet.intersection(names1, names2) |> MapSet.to_list()
    }
  end
  
  defp generate_diff_summary(state1, state2) do
    %{
      networks_added: length(diff_resources(state1.networks, state2.networks).added),
      networks_removed: length(diff_resources(state1.networks, state2.networks).removed),
      pools_added: length(diff_resources(state1.pools, state2.pools).added),
      pools_removed: length(diff_resources(state1.pools, state2.pools).removed),
      volumes_added: length(diff_resources(state1.volumes, state2.volumes).added),
      volumes_removed: length(diff_resources(state1.volumes, state2.volumes).removed),
      domains_added: length(diff_resources(state1.domains, state2.domains).added),
      domains_removed: length(diff_resources(state1.domains, state2.domains).removed)
    }
  end
  
  defp validate_domain_network_references(state) do
    network_names = MapSet.new(state.networks, & &1.name)
    
    invalid_refs = Enum.filter(state.domains, fn domain ->
      domain.network && domain.network not in network_names
    end)
    
    case invalid_refs do
      [] -> :ok
      [domain | _] -> {:error, "Domain '#{domain.name}' references non-existent network '#{domain.network}'"}
    end
  end
  
  defp validate_domain_pool_references(state) do
    pool_names = MapSet.new(state.pools, & &1.name)
    
    invalid_refs = Enum.filter(state.domains, fn domain ->
      domain.pool && domain.pool not in pool_names
    end)
    
    case invalid_refs do
      [] -> :ok
      [domain | _] -> {:error, "Domain '#{domain.name}' references non-existent pool '#{domain.pool}'"}
    end
  end
  
  defp validate_volume_pool_references(state) do
    pool_names = MapSet.new(state.pools, & &1.name)
    
    invalid_refs = Enum.filter(state.volumes, fn volume ->
      volume.pool && volume.pool not in pool_names
    end)
    
    case invalid_refs do
      [] -> :ok
      [volume | _] -> {:error, "Volume '#{volume.name}' references non-existent pool '#{volume.pool}'"}
    end
  end
end
