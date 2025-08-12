defmodule Mix.Tasks.Romulus.Plan do
  @moduledoc """
  Plan infrastructure changes by comparing current and desired states.
  """

  use Mix.Task
  
  alias RomulusElixir.{Config, State, Planner}

  @shortdoc "Plan infrastructure changes"

  @spec run([String.t()]) :: :ok
  def run(args) do
    Application.ensure_all_started(:romulus_elixir)

    {opts, _, _} = OptionParser.parse(args,
      switches: [config: :string, format: :string, verbose: :boolean],
      aliases: [c: :config, f: :format, v: :verbose]
    )

    config_path = Keyword.get(opts, :config, "romulus.yaml")
    format = Keyword.get(opts, :format, "text")

    with {:ok, config} <- Config.load(config_path),
         {:ok, current_state} <- State.fetch_current(),
         {:ok, desired_state} <- State.from_config(config),
         {:ok, plan} <- Planner.create_plan(current_state, desired_state) do
      display_plan(plan, format)
    else
      {:error, reason} ->
        Mix.shell().error("Planning failed: #{reason}")
        exit({:shutdown, 1})
    end
  end

  @spec display_plan([Planner.Action.t()], String.t()) :: :ok
  defp display_plan(plan, "json") do
    json_plan = %{
      actions: Enum.map(plan, &action_to_json/1),
      summary: %{
        total_changes: length(plan),
        creates: count_actions(plan, :create),
        updates: count_actions(plan, :update),
        destroys: count_actions(plan, :destroy)
      }
    }

    IO.puts(Jason.encode!(json_plan, pretty: true))
  end

  defp display_plan(plan, _format) do
    formatted_plan = Planner.format_plan(plan)
    IO.puts(formatted_plan)

    if length(plan) > 0 do
      Mix.shell().info("\nTo apply these changes, run: mix romulus.apply")
    end
  end

  @spec action_to_json(Planner.Action.t()) :: map()
  defp action_to_json(%Planner.Action{} = action) do
    %{
      type: action.type,
      resource_type: action.resource_type,
      resource_name: extract_resource_name(action.resource),
      reason: action.reason
    }
  end

  @spec extract_resource_name(term()) :: String.t()
  defp extract_resource_name(%{name: name}) when is_binary(name), do: name
  defp extract_resource_name(_), do: "unknown"

  @spec count_actions([Planner.Action.t()], atom()) :: non_neg_integer()
  defp count_actions(actions, action_type) do
    Enum.count(actions, &(&1.type == action_type))
  end
end
