defmodule Romulus.Libvirt.Virsh do
  @moduledoc """
  Virsh adapter for libvirt operations.
  Uses shell commands to interact with libvirt via virsh.
  """

  @behaviour Romulus.Libvirt.Adapter

  require Logger
  alias Romulus.State.Schema.{VM, Network, Pool, Volume}

  @virsh_timeout 30_000

  def list_domains do
    case execute("virsh list --all --name") do
      {:ok, output} ->
        domains =
          output
          |> String.split("\n", trim: true)
          |> Enum.reject(&(&1 == ""))

        {:ok, domains}

      error ->
        error
    end
  end

  def get_domain(name) do
    with {:ok, _} <- execute("virsh dominfo #{name}"),
         {:ok, xml} <- execute("virsh dumpxml #{name}") do
      {:ok, parse_domain_xml(xml)}
    end
  end

  def create_domain(%VM{} = vm, cloudinit_iso) do
    xml = generate_domain_xml(vm, cloudinit_iso)
    xml_file = "/tmp/#{vm.name}.xml"

    with :ok <- File.write(xml_file, xml),
         {:ok, _} <- execute("virsh define #{xml_file}"),
         {:ok, _} <- execute("virsh start #{vm.name}") do
      File.rm(xml_file)
      :ok
    else
      error ->
        File.rm(xml_file)
        error
    end
  end

  def destroy_domain(name) do
    with {:ok, _} <- execute("virsh destroy #{name}"),
         {:ok, _} <- execute("virsh undefine #{name} --remove-all-storage") do
      :ok
    end
  end

  def delete_domain(name) do
    destroy_domain(name)
  end

  def list_networks do
    case execute("virsh net-list --all --name") do
      {:ok, output} ->
        networks =
          output
          |> String.split("\n", trim: true)
          |> Enum.reject(&(&1 == ""))

        {:ok, networks}

      error ->
        error
    end
  end

  def get_network(name) do
    with {:ok, _} <- execute("virsh net-info #{name}"),
         {:ok, xml} <- execute("virsh net-dumpxml #{name}") do
      {:ok, parse_network_xml(xml)}
    end
  end

  def create_network(%Network{} = network) do
    xml = generate_network_xml(network)
    xml_file = "/tmp/#{network.name}.xml"

    with :ok <- File.write(xml_file, xml),
         {:ok, _} <- execute("virsh net-define #{xml_file}"),
         {:ok, _} <- execute("virsh net-start #{network.name}"),
         {:ok, _} <- execute("virsh net-autostart #{network.name}") do
      File.rm(xml_file)
      :ok
    else
      error ->
        File.rm(xml_file)
        error
    end
  end

  def destroy_network(name) do
    with {:ok, _} <- execute("virsh net-destroy #{name}"),
         {:ok, _} <- execute("virsh net-undefine #{name}") do
      :ok
    end
  end

  def list_pools do
    case execute("virsh pool-list --all --name") do
      {:ok, output} ->
        pools =
          output
          |> String.split("\n", trim: true)
          |> Enum.reject(&(&1 == ""))

        {:ok, pools}

      error ->
        error
    end
  end

  def get_pool(name) do
    with {:ok, _} <- execute("virsh pool-info #{name}"),
         {:ok, xml} <- execute("virsh pool-dumpxml #{name}") do
      {:ok, parse_pool_xml(xml)}
    end
  end

  def create_pool(%Pool{} = pool) do
    xml = generate_pool_xml(pool)
    xml_file = "/tmp/#{pool.name}.xml"

    with :ok <- File.write(xml_file, xml),
         {:ok, _} <- execute("virsh pool-define #{xml_file}"),
         {:ok, _} <- execute("virsh pool-build #{pool.name}"),
         {:ok, _} <- execute("virsh pool-start #{pool.name}"),
         {:ok, _} <- execute("virsh pool-autostart #{pool.name}") do
      File.rm(xml_file)
      :ok
    else
      error ->
        File.rm(xml_file)
        error
    end
  end

  def destroy_pool(name) do
    with {:ok, _} <- execute("virsh pool-destroy #{name}"),
         {:ok, _} <- execute("virsh pool-undefine #{name}") do
      :ok
    end
  end

  def list_volumes(pool_name) do
    case execute("virsh vol-list #{pool_name} --name") do
      {:ok, output} ->
        volumes =
          output
          |> String.split("\n", trim: true)
          |> Enum.reject(&(&1 == ""))

        {:ok, volumes}

      error ->
        error
    end
  end

  def get_volume(pool_name, volume_name) do
    with {:ok, _} <- execute("virsh vol-info #{volume_name} --pool #{pool_name}"),
         {:ok, xml} <- execute("virsh vol-dumpxml #{volume_name} --pool #{pool_name}") do
      {:ok, parse_volume_xml(xml)}
    end
  end

  def create_volume(%Volume{} = volume) do
    if volume.source do
      # Download base image
      with {:ok, _} <- download_image(volume) do
        create_volume_from_base(volume)
      end
    else
      create_volume_from_base(volume)
    end
  end

  defp create_volume_from_base(%Volume{} = volume) do
    if volume.base_volume do
      # Clone from base volume
      execute(
        "virsh vol-clone #{volume.base_volume} #{volume.name} --pool #{volume.pool}"
      )
    else
      # Create new volume
      execute(
        "virsh vol-create-as #{volume.pool} #{volume.name} #{volume.size}B --format #{volume.format}"
      )
    end
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp download_image(%Volume{source: url} = volume) do
    target_path = "/var/lib/libvirt/images/#{volume.pool}/#{volume.name}"
    execute("wget -O #{target_path} #{url}", timeout: 300_000)
  end

  def delete_volume(pool_name, volume_name) do
    case execute("virsh vol-delete #{volume_name} --pool #{pool_name}") do
      {:ok, _} -> :ok
      error -> error
    end
  end

  def create_cloudinit_iso(name, pool, user_data, network_config) do
    temp_dir = "/tmp/cloudinit-#{name}"
    iso_path = "/var/lib/libvirt/images/#{pool}/#{name}.iso"

    with :ok <- File.mkdir_p(temp_dir),
         :ok <- File.write("#{temp_dir}/user-data", user_data),
         :ok <- File.write("#{temp_dir}/network-config", network_config),
         :ok <- File.write("#{temp_dir}/meta-data", "instance-id: #{name}\n"),
         {:ok, _} <-
           execute(
             "genisoimage -output #{iso_path} -volid cidata -joliet -rock #{temp_dir}/*"
           ) do
      File.rm_rf(temp_dir)
      {:ok, iso_path}
    else
      error ->
        File.rm_rf(temp_dir)
        error
    end
  end

  # XML Generation
  defp generate_domain_xml(%VM{} = vm, cloudinit_iso) do
    """
    <domain type='kvm'>
      <name>#{vm.name}</name>
      <memory unit='MiB'>#{vm.memory}</memory>
      <vcpu placement='static'>#{vm.vcpu}</vcpu>
      <os>
        <type arch='x86_64' machine='pc-q35-8.2'>hvm</type>
        <boot dev='hd'/>
      </os>
      <features>
        <acpi/>
        <apic/>
        <vmport state='off'/>
      </features>
      <cpu mode='host-passthrough' check='none'/>
      <clock offset='utc'>
        <timer name='rtc' tickpolicy='catchup'/>
        <timer name='pit' tickpolicy='delay'/>
        <timer name='hpet' present='no'/>
      </clock>
      <on_poweroff>destroy</on_poweroff>
      <on_reboot>restart</on_reboot>
      <on_crash>destroy</on_crash>
      <devices>
        <emulator>/usr/bin/qemu-system-x86_64</emulator>
        <disk type='file' device='disk'>
          <driver name='qemu' type='qcow2'/>
          <source file='/var/lib/libvirt/images/#{vm.pool}/#{vm.name}-disk'/>
          <target dev='vda' bus='virtio'/>
        </disk>
        <disk type='file' device='cdrom'>
          <driver name='qemu' type='raw'/>
          <source file='#{cloudinit_iso}'/>
          <target dev='hda' bus='ide'/>
          <readonly/>
        </disk>
        <interface type='network'>
          <source network='#{vm.network}'/>
          <model type='virtio'/>
        </interface>
        <console type='pty'>
          <target type='serial' port='0'/>
        </console>
        <graphics type='spice' autoport='yes'>
          <listen type='address'/>
        </graphics>
      </devices>
    </domain>
    """
  end

  defp generate_network_xml(%Network{} = network) do
    [address | _] = network.addresses

    """
    <network>
      <name>#{network.name}</name>
      <forward mode='#{network.mode}'/>
      <domain name='#{network.domain}'/>
      <ip address='#{get_gateway(address)}' netmask='#{get_netmask(address)}'>
        #{if network.dhcp_enabled, do: generate_dhcp_xml(address), else: ""}
      </ip>
      #{if network.dns_enabled, do: "<dns enable='yes'/>", else: ""}
    </network>
    """
  end

  defp generate_dhcp_xml(cidr) do
    base = cidr |> String.split("/") |> List.first() |> String.split(".") |> Enum.take(3) |> Enum.join(".")
    
    """
    <dhcp>
      <range start='#{base}.100' end='#{base}.254'/>
    </dhcp>
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

  # XML Parsing (simplified)
  defp parse_domain_xml(_xml), do: %{}
  defp parse_network_xml(_xml), do: %{}
  defp parse_pool_xml(_xml), do: %{}
  defp parse_volume_xml(_xml), do: %{}

  # Utility functions
  defp get_gateway(cidr) do
    cidr
    |> String.split("/")
    |> List.first()
    |> String.split(".")
    |> List.update_at(3, fn _ -> "1" end)
    |> Enum.join(".")
  end

  defp get_netmask("10.10.10.0/24"), do: "255.255.255.0"
  defp get_netmask(_), do: "255.255.255.0"

  defp execute(command, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @virsh_timeout)
    Logger.debug("Executing: #{command}")

    case System.cmd("bash", ["-c", command], stderr_to_stdout: true, timeout: timeout) do
      {output, 0} ->
        Logger.debug("Success: #{String.trim(output)}")
        {:ok, String.trim(output)}

      {output, code} ->
        Logger.error("Command failed (#{code}): #{String.trim(output)}")
        {:error, "Command failed (#{code}): #{String.trim(output)}"}
    end
  end
end