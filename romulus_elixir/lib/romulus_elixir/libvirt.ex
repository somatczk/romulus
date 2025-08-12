defmodule RomulusElixir.Libvirt do
  @moduledoc """
  Main interface for libvirt operations.
  Delegates to the configured adapter (Virsh or NIF).
  """
  
  alias RomulusElixir.Libvirt.Virsh
  
  # Resource structs
  defmodule Network do
    @enforce_keys [:name]
    defstruct [:name, :mode, :domain, :addresses, :dhcp, :dns, :uuid, :active]
  end
  
  defmodule Pool do
    @enforce_keys [:name]
    defstruct [:name, :type, :path, :uuid, :active, :capacity, :allocation]
  end
  
  defmodule Volume do
    @enforce_keys [:name]
    defstruct [:name, :pool, :source, :format, :size, :base_volume, :type, :node_type, :node_index, :path]
  end
  
  defmodule Domain do
    @enforce_keys [:name]
    defstruct [:name, :memory, :vcpu, :network, :disk_volume, :cloudinit_volume, :pool, :ip_address, :uuid, :state, :mac_address]
  end
  
  @adapter Application.compile_env(:romulus_elixir, :libvirt_adapter, Virsh)
  
  @doc """
  List all networks.
  """
  def list_networks do
    @adapter.list_networks()
  end
  
  @doc """
  Create a network.
  """
  def create_network(%Network{} = network) do
    @adapter.create_network(network)
  end
  
  @doc """
  Delete a network.
  """
  def delete_network(name) do
    @adapter.delete_network(name)
  end
  
  @doc """
  List all storage pools.
  """
  def list_pools do
    @adapter.list_pools()
  end
  
  @doc """
  Create a storage pool.
  """
  def create_pool(%Pool{} = pool) do
    @adapter.create_pool(pool)
  end
  
  @doc """
  Delete a storage pool.
  """
  def delete_pool(name) do
    @adapter.delete_pool(name)
  end
  
  @doc """
  List all volumes.
  """
  def list_volumes(pool_name \\ nil) do
    @adapter.list_volumes(pool_name)
  end
  
  @doc """
  Create a volume.
  """
  def create_volume(%Volume{} = volume) do
    @adapter.create_volume(volume)
  end
  
  @doc """
  Delete a volume.
  """
  def delete_volume(name, pool) do
    @adapter.delete_volume(name, pool)
  end
  
  @doc """
  List all domains (VMs).
  """
  def list_domains do
    @adapter.list_domains()
  end
  
  @doc """
  Create a domain (VM).
  """
  def create_domain(%Domain{} = domain) do
    @adapter.create_domain(domain)
  end
  
  @doc """
  Start a domain.
  """
  def start_domain(name) do
    @adapter.start_domain(name)
  end
  
  @doc """
  Stop a domain.
  """
  def stop_domain(name) do
    @adapter.stop_domain(name)
  end
  
  @doc """
  Delete a domain.
  """
  def delete_domain(name) do
    @adapter.delete_domain(name)
  end
  
  @doc """
  Get domain info.
  """
  def get_domain_info(name) do
    @adapter.get_domain_info(name)
  end
  
  @doc """
  Check if a resource exists.
  """
  def exists?(type, name) do
    @adapter.exists?(type, name)
  end
end