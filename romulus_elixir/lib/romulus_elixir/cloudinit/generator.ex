defmodule RomulusElixir.CloudInit.Generator do
  @moduledoc """
  Generates cloud-init ISO images for VM provisioning.
  """
  
  require Logger
  
  @doc """
  Create a cloud-init ISO from the provided volume configuration.
  """
  def create_iso(%{node_type: node_type, node_index: node_index, pool: _pool, name: name}) do
    # Load configuration
    {:ok, config} = RomulusElixir.load_config()
    
    # Generate cloud-init data
    {:ok, cloudinit_data} = RomulusElixir.CloudInit.Renderer.generate_node_cloudinit(
      node_type,
      node_index,
      config
    )
    
    # Create temporary directory for ISO contents
    temp_dir = System.tmp_dir!()
    iso_dir = Path.join(temp_dir, "cloudinit_#{name}_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(iso_dir)
    
    # Write cloud-init files
    File.write!(Path.join(iso_dir, "user-data"), cloudinit_data.user_data)
    File.write!(Path.join(iso_dir, "network-config"), cloudinit_data.network_config)
    File.write!(Path.join(iso_dir, "meta-data"), "instance-id: #{name}\nlocal-hostname: #{name}\n")
    
    # Generate ISO
    iso_path = Path.join(temp_dir, "#{name}.iso")
    
    case System.cmd("genisoimage", [
      "-output", iso_path,
      "-volid", "cidata",
      "-joliet",
      "-rock",
      iso_dir
    ], stderr_to_stdout: true) do
      {_, 0} ->
        # Clean up temp directory
        File.rm_rf!(iso_dir)
        {:ok, iso_path}
        
      {output, code} ->
        File.rm_rf!(iso_dir)
        {:error, "Failed to create ISO (exit #{code}): #{output}"}
    end
  end
end