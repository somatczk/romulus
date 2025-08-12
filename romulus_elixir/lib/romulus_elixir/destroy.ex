defmodule Mix.Tasks.Romulus.Destroy do
  @moduledoc """
  Destroy infrastructure by removing all managed resources.
  """

  use Mix.Task
  
  alias RomulusElixir.{Config, State, Planner, Executor}

  @shortdoc "Destroy infrastructure"

  @spec run([String.t()]) :: :ok
  def run(args) do
    Application.ensure_all_started(:romulus_elixir)

    {opts, _, _} = OptionParser.parse(args,
      switches: [config: :string, auto_approve: :boolean, force: :boolean],
      aliases: [c: :config, y: :auto_approve, f: :force]
    )

    config_path = Keyword.get(opts, :config, "romulus.yaml")
    auto_approve? = Keyword.get(opts, :auto_approve, false)
    force? = Keyword.get(opts, :force, false)

    with {:ok, config} <- Config.load(config_path),
         {:ok, current_state} <- State.fetch_current() do
      destroy_infrastructure(current_state, config, auto_approve?, force?)
    else
      {:error, reason} ->
        Mix.shell().error("Destroy failed: #{reason}")
        exit({:shutdown, 1})
    end
  end

  @spec destroy_infrastructure(State.t(), map(), boolean(), boolean()) :: :ok
  defp destroy_infrastructure(current_state, _config, auto_approve?, force?) do
    empty_state = %State{domains: [], networks: [], pools: [], volumes: []}

    {:ok, plan} = Planner.create_plan(current_state, empty_state)
    destroy_actions = Enum.filter(plan, &(&1.type == :destroy))
    
    if length(destroy_actions) == 0 do
      Mix.shell().info("No infrastructure to destroy.")
    else
      execute_destroy(destroy_actions, auto_approve?, force?)
    end
  end

  @spec execute_destroy([Planner.Action.t()], boolean(), boolean()) :: :ok
  defp execute_destroy(actions, auto_approve?, force?) do
    formatted_plan = Planner.format_plan(actions)
    IO.puts(formatted_plan)

    proceed = if force? do
      Mix.shell().info("WARNING: Force mode enabled - skipping confirmation")
      true
    else
      auto_approve? or confirm_destroy(length(actions))
    end

    if proceed do
      case Executor.execute(actions) do
        {:ok, :success} ->
          Mix.shell().info("Infrastructure destroyed successfully!")
        
        {:error, reason} ->
          Mix.shell().error("Destroy failed: #{reason}")
          exit({:shutdown, 1})
      end
    else
      Mix.shell().info("Destroy cancelled.")
    end
  end

  @spec confirm_destroy(non_neg_integer()) :: boolean()
  defp confirm_destroy(count) do
    Mix.shell().error("WARNING: This will destroy #{count} resource(s)!")
    Mix.shell().error("This action cannot be undone.")
    Mix.shell().yes?("Are you sure you want to proceed?")
  end
end
