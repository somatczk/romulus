defmodule Mix.Tasks.Romulus.Apply do
  @moduledoc """
  Apply infrastructure changes by executing a plan.
  """

  use Mix.Task
  
  alias RomulusElixir.{Config, State, Planner, Executor}

  @shortdoc "Apply infrastructure changes"

  @spec run([String.t()]) :: :ok
  def run(args) do
    Application.ensure_all_started(:romulus_elixir)

    {opts, _, _} = OptionParser.parse(args,
      switches: [config: :string, auto_approve: :boolean, verbose: :boolean],
      aliases: [c: :config, y: :auto_approve, v: :verbose]
    )

    config_path = Keyword.get(opts, :config, "romulus.yaml")
    auto_approve? = Keyword.get(opts, :auto_approve, false)
    verbose? = Keyword.get(opts, :verbose, false)

    with {:ok, config} <- Config.load(config_path),
         {:ok, current_state} <- State.fetch_current(),
         {:ok, desired_state} <- State.from_config(config),
         {:ok, plan} <- Planner.create_plan(current_state, desired_state) do
      apply_plan(plan, auto_approve?, verbose?)
    else
      {:error, reason} ->
        Mix.shell().error("Apply failed: #{reason}")
        exit({:shutdown, 1})
    end
  end

  @spec apply_plan([Planner.Action.t()], boolean(), boolean()) :: :ok
  defp apply_plan([], _, _) do
    Mix.shell().info("Infrastructure is up to date. No changes needed.")
  end

  defp apply_plan(plan, auto_approve?, verbose?) do
    if verbose? do
      formatted_plan = Planner.format_plan(plan)
      IO.puts(formatted_plan)
    else
      Mix.shell().info("Found #{length(plan)} change(s) to apply.")
    end

    if auto_approve? or confirm_apply() do
      case Executor.execute(plan) do
        {:ok, :success} ->
          Mix.shell().info("Infrastructure changes applied successfully!")
        
        {:error, reason} ->
          Mix.shell().error("Execution failed: #{reason}")
          exit({:shutdown, 1})
      end
    else
      Mix.shell().info("Apply cancelled.")
    end
  end

  @spec confirm_apply() :: boolean()
  defp confirm_apply do
    Mix.shell().yes?("Do you want to apply these changes?")
  end
end
