defmodule Romulus.CloudInit.Renderer do
  @moduledoc """
  Renders cloud-init templates using native EEx templating.
  Provides pure Elixir template processing without external dependencies.
  """
  
  require Logger
  
  @doc """
  Render all cloud-init templates for validation.
  """
  def render_all(config) do
    nodes = config[:nodes]
    
    # Render masters
    master_results = for i <- 1..nodes[:masters][:count] do
      case generate_node_cloudinit(:master, i, config) do
        {:ok, data} -> {:ok, "k8s-master-#{i}", data}
        error -> error
      end
    end
    
    # Render workers
    worker_results = for i <- 1..nodes[:workers][:count] do
      case generate_node_cloudinit(:worker, i, config) do
        {:ok, data} -> {:ok, "k8s-worker-#{i}", data}
        error -> error
      end
    end
    
    {:ok, master_results ++ worker_results}
  end
  
  @doc """
  Renders cloud-init user-data template.
  """
  def render_user_data(template_path, variables) do
    Logger.debug("Rendering user-data from #{template_path}")
    
    case File.read(template_path) do
      {:ok, template} ->
        rendered = substitute_variables(template, variables)
        {:ok, rendered}
        
      {:error, reason} ->
        {:error, "Failed to read template: #{reason}"}
    end
  end
  
  @doc """
  Renders network configuration template.
  """
  def render_network_config(template_path, variables) do
    Logger.debug("Rendering network-config from #{template_path}")
    
    case File.read(template_path) do
      {:ok, template} ->
        rendered = substitute_variables(template, variables)
        {:ok, rendered}
        
      {:error, reason} ->
        {:error, "Failed to read template: #{reason}"}
    end
  end
  
  @doc """
  Creates cloud-init ISO for a VM.
  """
  def create_cloudinit_iso(vm_name, pool_name, user_data, network_config) do
    temp_dir = System.tmp_dir!()
    iso_dir = Path.join(temp_dir, "cloudinit_#{vm_name}_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(iso_dir)
    
    # Write cloud-init files
    File.write!(Path.join(iso_dir, "user-data"), user_data)
    File.write!(Path.join(iso_dir, "network-config"), network_config)
    File.write!(Path.join(iso_dir, "meta-data"), "instance-id: #{vm_name}\nlocal-hostname: #{vm_name}\n")
    
    # Create ISO
    pool_path = get_pool_path(pool_name)
    iso_path = Path.join(pool_path, "#{vm_name}-init.iso")
    
    case System.cmd("genisoimage", [
      "-output", iso_path,
      "-volid", "cidata",
      "-joliet",
      "-rock",
      iso_dir
    ], stderr_to_stdout: true) do
      {_, 0} ->
        File.rm_rf!(iso_dir)
        {:ok, iso_path}
        
      {output, code} ->
        File.rm_rf!(iso_dir)
        {:error, "Failed to create ISO (exit #{code}): #{output}"}
    end
  end
  
  @doc """
  Validates cloud-init YAML.
  """
  def validate_yaml(content) do
    case YamlElixir.read_from_string(content) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, "Invalid YAML: #{inspect(reason)}"}
    end
  end
  
  @doc """
  Generates cloud-init data for a node.
  """
  def generate_node_cloudinit(node_type, node_index, config) do
    hostname = "k8s-#{node_type}-#{node_index}"
    nodes = config[:nodes]
    ssh = config[:ssh]
    
    # Calculate IP based on node type and index
    ip = case node_type do
      :master -> "#{nodes[:masters][:ip_prefix]}#{node_index}"
      :worker -> "#{nodes[:workers][:ip_prefix]}#{node_index}"
    end
    
    ssh_key = case File.read(ssh[:public_key_path]) do
      {:ok, key} -> String.trim(key)
      _ -> ""
    end
    
    variables = [
      hostname: hostname,
      ssh_key: ssh_key,
      node_ip: ip,
      ip_address: ip
    ]
    
    # Get template paths
    template_dir = Path.join([:code.priv_dir(:romulus_elixir), "cloud-init"])
    user_data_template = Path.join(template_dir, "cloud-init-#{node_type}.yml")
    network_template = Path.join(template_dir, "network-config.yml")
    
    with {:ok, user_data} <- render_user_data(user_data_template, variables),
         {:ok, network_config} <- render_network_config(network_template, variables),
         :ok <- validate_yaml(user_data),
         :ok <- validate_yaml(network_config) do
      {:ok, %{user_data: user_data, network_config: network_config}}
    end
  end
  
  
  @doc """
  Substitutes ${variable} placeholders with values from the variables keyword list.
  
  This function handles shell-style variable substitution used in cloud-init templates.
  """
  def substitute_variables(template, variables) do
    Enum.reduce(variables, template, fn {key, value}, acc ->
      variable_pattern = "${#{key}}"
      String.replace(acc, variable_pattern, to_string(value))
    end)
  end
  
  @doc """
  Validates that all variable placeholders in a template are satisfied by the provided variables.
  
  Returns a list of missing variable names, or empty list if all are satisfied.
  """
  def validate_template_variables(template, variables) do
    # Extract all ${variable} patterns from template
    variable_patterns = Regex.scan(~r/\$\{([^}]+)\}/, template)
    template_variables = 
      variable_patterns
      |> Enum.map(fn [_, var] -> String.to_atom(var) end)
      |> Enum.uniq()
    
    # Get provided variable keys
    provided_variables = Keyword.keys(variables)
    
    # Find missing variables
    template_variables -- provided_variables
  end
  
  defp get_pool_path(pool_name) do
    # Default pool path - in production, query from libvirt
    "/var/lib/libvirt/images/#{pool_name}"
  end
end
