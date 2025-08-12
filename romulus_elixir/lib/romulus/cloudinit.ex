defmodule Romulus.CloudInit do
  @moduledoc """
  Main interface for cloud-init operations.
  """
  
  alias Romulus.CloudInit.{Renderer, Generator}
  
  defdelegate render_user_data(template_path, variables), to: Renderer
  defdelegate render_network_config(template_path, variables), to: Renderer
  defdelegate generate_node_cloudinit(node_type, node_index, config), to: Renderer
  defdelegate create_iso(volume), to: Generator
end