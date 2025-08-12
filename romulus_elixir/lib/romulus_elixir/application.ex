defmodule RomulusElixir.Application do
  @moduledoc false
  
  use Application
  require Logger
  
  @impl true
  def start(_type, _args) do
    Logger.info("Starting Romulus application...")
    
    children = [
      # You can add process supervisors here if needed for long-running operations
      # For example, a GenServer to track infrastructure state
    ]
    
    opts = [strategy: :one_for_one, name: RomulusElixir.Supervisor]
    Supervisor.start_link(children, opts)
  end
  
end