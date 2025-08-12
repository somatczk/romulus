defmodule RomulusElixir.Libvirt.Virsh do
  @moduledoc """
  Virsh adapter for libvirt operations in the RomulusElixir application.
  Uses shell commands to interact with libvirt via virsh CLI.
  
  This module provides functions to manage libvirt resources:
  - Networks: create, list, delete
  - Storage pools: create, list, delete  
  - Storage volumes: create, list, delete
  - Domains (VMs): create, list, start, stop, delete
  - Cloud-init ISOs: create for VM initialization
  """

  require Logger
  alias RomulusElixir.Libvirt.{Network, Pool, Volume, Domain}

  @virsh_timeout 30_000

  @doc """
  Lists all libvirt networks.
  
  Returns `{:ok, networks}` where networks is a list of Network structs,
  or `{:error, reason}` on failure.
  """
  @spec list_networks() :: {:ok, [Network.t()]} | {:error, String.t()}
  def list_networks do
    case execute_virsh("net-list --all --name") do
      {:ok, output} ->
        networks = 
          output
          |> String.split("\n", trim: true)
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(&build_network_struct/1)
        
        {:ok, networks}
        
      error -> error
    end
  end

  @doc """
  Creates a libvirt network from a Network struct.
  """
  @spec create_network(Network.t()) :: :ok | {:error, String.t()}
  def create_network(%Network{} = network) do
    xml = generate_network_xml(network)
    xml_file = "/tmp/#{network.name}-network.xml"

    with :ok <- File.write(xml_file, xml),
         {:ok, _} <- execute_virsh("net-define #{xml_file}"),
         {:ok, _} <- execute_virsh("net-start #{network.name}"),
         {:ok, _} <- execute_virsh("net-autostart #{network.name}") do
      File.rm(xml_file)
      :ok
    else
      error ->
        File.rm(xml_file)
        error
    end
  end

  @doc """
  Deletes a libvirt network by name.
  """
  @spec delete_network(String.t()) :: :ok | {:error, String.t()}
  def delete_network(name) do
    with {:ok, _} <- execute_virsh("net-destroy #{name}"),
         {:ok, _} <- execute_virsh("net-undefine #{name}") do
      :ok
    end
  end

  @doc """
  Lists all libvirt storage pools.
  """
  @spec list_pools() :: {:ok, [Pool.t()]} | {:error, String.t()}
  def list_pools do
    case execute_virsh("pool-list --all --name") do
      {:ok, output} ->
        pools = 
          output
          |> String.split("\n", trim: true)
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(&build_pool_struct/1)
        
        {:ok, pools}
        
      error -> error
    end
  end

  @doc """
  Creates a libvirt storage pool from a Pool struct.
  """
  @spec create_pool(Pool.t()) :: :ok | {:error, String.t()}
  def create_pool(%Pool{} = pool) do
    xml = generate_pool_xml(pool)
    xml_file = "/tmp/#{pool.name}-pool.xml"

    with :ok <- File.write(xml_file, xml),
         {:ok, _} <- execute_virsh("pool-define #{xml_file}"),
         {:ok, _} <- execute_virsh("pool-build #{pool.name}"),
         {:ok, _} <- execute_virsh("pool-start #{pool.name}"),
         {:ok, _} <- execute_virsh("pool-autostart #{pool.name}") do
      File.rm(xml_file)
      :ok
    else
      error ->
        File.rm(xml_file)
        error
    end
  end

  @doc """
  Deletes a libvirt storage pool by name.
  """
  @spec delete_pool(String.t()) :: :ok | {:error, String.t()}
  def delete_pool(name) do
    with {:ok, _} <- execute_virsh("pool-destroy #{name}"),
         {:ok, _} <- execute_virsh("pool-undefine #{name}") do
      :ok
    end
  end

  @doc """
  Lists all storage volumes in a pool.
  """
  @spec list_volumes(String.t()) :: {:ok, [Volume.t()]} | {:error, String.t()}
  def list_volumes(pool_name) do
    case execute_virsh("vol-list #{pool_name}") do
      {:ok, output} ->
        volumes = 
          output
          |> String.split("\n", trim: true)
          |> Enum.drop(2)  # Skip header lines (Name Path and ----)
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(&parse_volume_line(&1, pool_name))
          |> Enum.reject(&is_nil/1)
        
        {:ok, volumes}
        
      error -> error
    end
  end

  @doc """
  Creates a storage volume from a Volume struct.
  """
  @spec create_volume(Volume.t()) :: :ok | {:error, String.t()}
  def create_volume(%Volume{} = volume) do
    if volume.source do
      with {:ok, _} <- download_base_image(volume) do
        create_volume_from_base(volume)
      end
    else
      create_volume_from_scratch(volume)
    end
  end

  @doc """
  Deletes a storage volume by name and pool.
  """
  @spec delete_volume(String.t(), String.t()) :: :ok | {:error, String.t()}
  def delete_volume(name, pool) do
    case execute_virsh("vol-delete #{name} --pool #{pool}") do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc """
  Lists all libvirt domains (VMs).
  """
  @spec list_domains() :: {:ok, [Domain.t()]} | {:error, String.t()}
  def list_domains do
    case execute_virsh("list --all --name") do
      {:ok, output} ->
        domains = 
          output
          |> String.split("\n", trim: true)
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(&build_domain_struct/1)
        
        {:ok, domains}
        
      error -> error
    end
  end

  @doc """
  Creates a libvirt domain from a Domain struct.
  """
  @spec create_domain(Domain.t()) :: :ok | {:error, String.t()}
  def create_domain(%Domain{} = domain) do
    xml = generate_domain_xml(domain)
    xml_file = "/tmp/#{domain.name}-domain.xml"

    with :ok <- File.write(xml_file, xml),
         {:ok, _} <- execute_virsh("define #{xml_file}") do
      File.rm(xml_file)
      :ok
    else
      error ->
        File.rm(xml_file)
        error
    end
  end
  
  @doc """
  Starts a libvirt domain.
  """
  @spec start_domain(String.t()) :: :ok | {:error, String.t()}
  def start_domain(name) do
    case execute_virsh("start #{name}") do
      {:ok, _} -> :ok
      error -> error
    end
  end
  
  @doc """
  Stops a libvirt domain gracefully.
  """
  @spec stop_domain(String.t()) :: :ok | {:error, String.t()}
  def stop_domain(name) do
    case execute_virsh("shutdown #{name}") do
      {:ok, _} -> :ok
      error -> error
    end
  end
  
  @doc """
  Destroys (force stops) and undefines a libvirt domain.
  """
  @spec delete_domain(String.t()) :: :ok | {:error, String.t()}
  def delete_domain(name) do
    with {:ok, _} <- execute_virsh("destroy #{name}"),
         {:ok, _} <- execute_virsh("undefine #{name} --remove-all-storage") do
      :ok
    end
  end
  
  @doc """
  Gets domain information.
  """
  @spec get_domain_info(String.t()) :: {:ok, map()} | {:error, String.t()}
  def get_domain_info(name) do
    case execute_virsh("dominfo #{name}") do
      {:ok, output} ->
        info = parse_dominfo_output(output)
        {:ok, info}
      error -> error
    end
  end
  
  @doc """
  Attaches a volume to a running domain.
  """
  @spec attach_volume(String.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def attach_volume(domain_name, volume_name, pool_name) do
    # Generate XML for the disk device
    disk_xml = generate_attach_disk_xml(volume_name, pool_name)
    xml_file = "/tmp/attach-#{domain_name}-#{:rand.uniform(10000)}.xml"
    
    with :ok <- File.write(xml_file, disk_xml),
         {:ok, _} <- execute_virsh("attach-device #{domain_name} #{xml_file} --live --config") do
      File.rm(xml_file)
      :ok
    else
      error ->
        File.rm(xml_file)
        error
    end
  end
  
  @doc """
  Detaches a volume from a running domain.
  """
  @spec detach_volume(String.t(), String.t()) :: :ok | {:error, String.t()}
  def detach_volume(domain_name, device_name) do
    case execute_virsh("detach-disk #{domain_name} #{device_name} --live --config") do
      {:ok, _} -> :ok
      error -> error
    end
  end
  
  @doc """
  Checks if a resource exists.
  """
  @spec exists?(atom(), String.t()) :: boolean()
  def exists?(:network, name) do
    case execute_virsh("net-info #{name}") do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end
  
  def exists?(:pool, name) do
    case execute_virsh("pool-info #{name}") do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end
  
  def exists?(:domain, name) do
    case execute_virsh("dominfo #{name}") do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end
  
  def exists?(_, _), do: false

  # Private helper functions

  defp execute_virsh(command, opts \\ []) do
    _timeout = Keyword.get(opts, :timeout, @virsh_timeout)
    full_command = "virsh #{command}"
    
    Logger.debug("Executing: #{full_command}")

    system_opts = [stderr_to_stdout: true]
    
    case System.cmd("bash", ["-c", full_command], system_opts) do
      {output, 0} ->
        Logger.debug("Success: #{String.trim(output)}")
        {:ok, String.trim(output)}

      {output, code} ->
        Logger.error("Command failed (#{code}): #{String.trim(output)}")
        {:error, "Command failed (#{code}): #{String.trim(output)}"}
    end
  end

  defp build_network_struct(name) do
    %Network{
      name: name,
      active: true,  # Simplified - would need to check actual state
      mode: "nat",
      addresses: ["192.168.1.0/24"]
    }
  end

  defp build_pool_struct(name) do
    %Pool{
      name: name,
      active: true,  # Simplified - would need to check actual state
      type: "dir",
      path: "/var/lib/libvirt/images/#{name}",
      capacity: 0,
      allocation: 0
    }
  end

  defp build_volume_struct(name, pool_name) do
    %Volume{
      name: name,
      pool: pool_name,
      format: "qcow2",
      size: "10G",
      path: "/var/lib/libvirt/images/#{pool_name}/#{name}"
    }
  end

  defp parse_volume_line(line, pool_name) do
    # Parse lines like " volume.qcow2  /path/to/volume.qcow2"
    case String.split(String.trim(line), ~r/\s+/, parts: 2) do
      [name | _] when name != "" ->
        build_volume_struct(name, pool_name)
      _ ->
        nil
    end
  end

  defp build_domain_struct(name) do
    %Domain{
      name: name,
      state: :running,  # Simplified - would need to check actual state
      memory: 1024,
      vcpu: 2
    }
  end

  defp generate_network_xml(%Network{} = network) do
    [address | _] = network.addresses

    """
    <network>
      <name>#{network.name}</name>
      <forward mode='#{network.mode}'/>
      <ip address='#{get_gateway(address)}' netmask='#{get_netmask(address)}'>
        <dhcp>
          <range start='#{get_dhcp_start(address)}' end='#{get_dhcp_end(address)}'/>
        </dhcp>
      </ip>
    </network>
    """
  end

  defp generate_pool_xml(%Pool{} = pool) do
    """
    <pool type='#{pool.type}'>
      <name>#{pool.name}</name>
      <target>
        <path>#{pool.path}</path>
      </target>
    </pool>
    """
  end

  defp generate_domain_xml(%Domain{} = domain) do
    """
    <domain type='kvm'>
      <name>#{domain.name}</name>
      <memory unit='MiB'>#{domain.memory}</memory>
      <vcpu placement='static'>#{domain.vcpu}</vcpu>
      <os>
        <type arch='x86_64' machine='pc'>hvm</type>
        <boot dev='hd'/>
      </os>
      <devices>
        <emulator>/usr/bin/qemu-system-x86_64</emulator>
        <disk type='file' device='disk'>
          <driver name='qemu' type='qcow2'/>
          <source file='/var/lib/libvirt/images/#{domain.pool || "default"}/#{domain.name}'/>
          <target dev='vda' bus='virtio'/>
        </disk>
        <interface type='network'>
          <source network='#{domain.network || "default"}'/>
          <model type='virtio'/>
        </interface>
      </devices>
    </domain>
    """
  end

  defp download_base_image(%Volume{source: url} = volume) do
    target_path = "/var/lib/libvirt/images/#{volume.pool}/#{volume.name}"
    execute_virsh("! wget -O #{target_path} #{url}")
  end

  defp create_volume_from_base(%Volume{} = volume) do
    if volume.base_volume do
      execute_virsh("vol-clone #{volume.base_volume} #{volume.name} --pool #{volume.pool}")
    else
      create_volume_from_scratch(volume)
    end
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp create_volume_from_scratch(%Volume{} = volume) do
    case execute_virsh("vol-create-as #{volume.pool} #{volume.name} #{volume.size} --format #{volume.format}") do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp parse_dominfo_output(output) do
    output
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [key, value] -> 
          Map.put(acc, String.trim(key), String.trim(value))
        _ -> 
          acc
      end
    end)
  end
  
  defp generate_attach_disk_xml(volume_name, pool_name) do
    """
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='/var/lib/libvirt/images/#{pool_name}/#{volume_name}'/>
      <target dev='vdb' bus='virtio'/>
    </disk>
    """
  end

  defp get_gateway(cidr) do
    cidr
    |> String.split("/")
    |> List.first()
    |> String.split(".")
    |> List.update_at(3, fn _ -> "1" end)
    |> Enum.join(".")
  end

  defp get_netmask(_cidr), do: "255.255.255.0"

  defp get_dhcp_start(cidr) do
    base_ip = get_base_ip(cidr)
    "#{base_ip}.100"
  end

  defp get_dhcp_end(cidr) do
    base_ip = get_base_ip(cidr)
    "#{base_ip}.254"
  end

  defp get_base_ip(cidr) do
    cidr
    |> String.split("/")
    |> List.first()
    |> String.split(".")
    |> Enum.take(3)
    |> Enum.join(".")
  end
end