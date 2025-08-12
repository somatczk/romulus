defmodule Romulus.CloudInit.Renderer do
  @moduledoc """
  Renders cloud-init templates using EEx.
  Provides native EEx template rendering for cloud-init configuration.
  """

  require Logger

  @doc """
  Renders cloud-init user-data template
  """
  def render_user_data(template_path, variables) do
    Logger.info("Rendering user-data from #{template_path}")
    
    case File.read(template_path) do
      {:ok, template} ->
        rendered = EEx.eval_string(template, variables)
        {:ok, rendered}

      {:error, reason} ->
        {:error, "Failed to read template: #{reason}"}
    end
  end

  @doc """
  Renders network configuration template
  """
  def render_network_config(template_path, variables) do
    Logger.info("Rendering network-config from #{template_path}")
    
    case File.read(template_path) do
      {:ok, template} ->
        rendered = EEx.eval_string(template, variables)
        {:ok, rendered}

      {:error, reason} ->
        {:error, "Failed to read template: #{reason}"}
    end
  end

  @doc """
  Creates cloud-init ISO for a VM
  """
  def create_cloudinit_iso(vm_name, pool_name, user_data, network_config) do
    adapter = get_adapter()
    adapter.create_cloudinit_iso(vm_name, pool_name, user_data, network_config)
  end

  @doc """
  Validates cloud-init YAML
  """
  def validate_yaml(content) do
    case YamlElixir.read_from_string(content) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, "Invalid YAML: #{inspect(reason)}"}
    end
  end

  @doc """
  Generates cloud-init data for a node
  """
  def generate_node_cloudinit(node_type, node_index, config) do
    hostname = "k8s-#{node_type}-#{node_index}"
    
    # Calculate IP based on node type and index
    ip = case node_type do
      :master -> "10.10.10.1#{node_index}"
      :worker -> "10.10.10.2#{node_index}"
    end

    ssh_key = case File.read(config.ssh_public_key_path) do
      {:ok, key} -> String.trim(key)
      _ -> ""
    end

    variables = [
      hostname: hostname,
      ssh_key: ssh_key,
      node_ip: ip,
      ip_address: ip
    ]

    # Get template paths from priv directory
    base_path = :code.priv_dir(:romulus_elixir)
    user_data_template = Path.join([base_path, "cloud-init", "cloud-init-#{node_type}.yml"])
    network_template = Path.join([base_path, "cloud-init", "network-config.yml"])

    with {:ok, user_data} <- render_user_data(user_data_template, variables),
         {:ok, network_config} <- render_network_config(network_template, variables),
         :ok <- validate_yaml(user_data),
         :ok <- validate_yaml(network_config) do
      {:ok, %{user_data: user_data, network_config: network_config}}
    end
  end

  defp get_adapter do
    Application.get_env(:romulus_elixir, :libvirt_adapter, Romulus.Libvirt.Virsh)
  end
end