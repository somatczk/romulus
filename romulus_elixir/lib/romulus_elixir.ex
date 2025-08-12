defmodule RomulusElixir do
  @moduledoc """
  Romulus - Native Elixir infrastructure automation for libvirt/KVM and Kubernetes.

  This module provides the main entry point for the Romulus system, delivering
  idempotent infrastructure management using pure Elixir and YAML configuration.

  ## Features

  - Idempotent infrastructure operations
  - Stateless architecture (queries libvirt directly)
  - Built-in safety confirmations
  - Native EEx cloud-init template rendering
  - Kubernetes cluster bootstrapping
  - Pure YAML configuration (no external dependencies)

  ## Usage

      iex> {:ok, plan} = RomulusElixir.plan()
      iex> {:ok, result} = RomulusElixir.apply()
      iex> {:ok, result} = RomulusElixir.destroy(force: true)

  """

  alias RomulusElixir.{Config, Planner, Executor, State}

  require Logger
  
  @doc """
  Loads configuration from the specified YAML file.

  ## Parameters

    * `path` - Path to the configuration file (default: "romulus.yaml")

  ## Returns

    * `{:ok, config}` - Successfully loaded configuration
    * `{:error, reason}` - Failed to load configuration

  ## Examples

      iex> RomulusElixir.load_config("config/production.yaml")
      {:ok, %{nodes: %{masters: %{count: 3}}, ...}}

  """
  def load_config(path \\ "romulus.yaml") do
    Config.load(path)
  end
  
  @doc """
  Generates an execution plan showing what changes would be made to the infrastructure.

  Compares the current state of libvirt resources with the desired state
  defined in the configuration and returns a plan of actions to reconcile them.

  ## Parameters

    * `config` - Optional configuration map. If nil, loads from "romulus.yaml"

  ## Returns

    * `{:ok, plan}` - Successfully generated plan
    * `{:error, reason}` - Failed to generate plan

  ## Examples

      iex> {:ok, plan} = RomulusElixir.plan()
      iex> length(plan)
      0

  """
  def plan(config \\ nil) do
    with {:ok, config} <- ensure_config(config),
         {:ok, current_state} <- State.fetch_current(),
         {:ok, desired_state} <- State.from_config(config),
         {:ok, plan} <- Planner.create_plan(current_state, desired_state) do
      {:ok, plan}
    end
  end
  
  @doc """
  Applies infrastructure changes according to the execution plan.

  This function generates a plan and then executes it, creating, updating,
  or destroying infrastructure resources as needed. Includes safety confirmations
  unless auto-approved.

  ## Parameters

    * `config` - Optional configuration map. If nil, loads from "romulus.yaml"
    * `opts` - Options list. Supported keys:
      * `:auto_approve` - Skip confirmation prompts (default: false)

  ## Returns

    * `{:ok, result}` - Successfully applied changes
    * `{:error, :cancelled}` - User cancelled the operation
    * `{:error, reason}` - Failed to apply changes

  ## Examples

      iex> RomulusElixir.apply()
      Plan to be executed:
      ...
      Do you want to apply this plan? (yes/no): yes
      {:ok, %{created: 5, updated: 2, destroyed: 0}}

      iex> RomulusElixir.apply(nil, auto_approve: true)
      {:ok, %{created: 5, updated: 2, destroyed: 0}}

  """
  def apply(config \\ nil, opts \\ []) do
    with {:ok, config} <- ensure_config(config),
         {:ok, plan} <- plan(config),
         :ok <- maybe_confirm_plan(plan, opts),
         {:ok, result} <- Executor.execute(plan) do
      {:ok, result}
    end
  end
  
  @doc """
  Destroys all managed infrastructure resources.

  Generates a plan to remove all currently managed infrastructure and
  executes it. This operation is irreversible and includes strong
  safety confirmations unless forced.

  ## Parameters

    * `config` - Optional configuration map. If nil, loads from "romulus.yaml"
    * `opts` - Options list. Supported keys:
      * `:force` - Skip confirmation prompts (default: false)

  ## Returns

    * `{:ok, result}` - Successfully destroyed infrastructure
    * `{:error, :cancelled}` - User cancelled the operation
    * `{:error, reason}` - Failed to destroy infrastructure

  ## Examples

      iex> RomulusElixir.destroy()
      WARNING: This will DESTROY all infrastructure!
      # User will be prompted for confirmation
      {:ok, %{destroyed: 10}}

  """
  def destroy(config \\ nil, opts \\ []) do
    with {:ok, _config} <- ensure_config(config),
         {:ok, current_state} <- State.fetch_current(),
         empty_state = State.empty(),
         {:ok, plan} <- Planner.create_plan(current_state, empty_state),
         :ok <- maybe_confirm_destroy(plan, opts),
         {:ok, result} <- Executor.execute(plan) do
      {:ok, result}
    end
  end
  
  @doc """
  Renders cloud-init templates for validation purposes.

  Processes all cloud-init templates with the configuration variables
  and outputs the rendered results. Useful for validating template
  syntax and variable substitution.

  ## Parameters

    * `config` - Optional configuration map. If nil, loads from "romulus.yaml"

  ## Returns

    * `{:ok, rendered_templates}` - Successfully rendered templates
    * `{:error, reason}` - Failed to render templates

  """
  def render_cloudinit(config \\ nil) do
    with {:ok, config} <- ensure_config(config) do
      RomulusElixir.CloudInit.Renderer.render_all(config)
    end
  end
  
  @doc """
  Bootstraps a Kubernetes cluster on the provisioned VMs.

  Performs the necessary steps to initialize a Kubernetes cluster
  including master initialization, worker node joining, and CNI setup.
  Should be run after infrastructure has been successfully provisioned.

  ## Parameters

    * `config` - Optional configuration map. If nil, loads from "romulus.yaml"

  ## Returns

    * `{:ok, result}` - Successfully bootstrapped cluster
    * `{:error, reason}` - Failed to bootstrap cluster

  """
  def bootstrap_k8s(config \\ nil) do
    with {:ok, config} <- ensure_config(config) do
      RomulusElixir.K8s.Bootstrap.run(config)
    end
  end
  
  defp ensure_config(nil), do: load_config()
  defp ensure_config(config), do: {:ok, config}
  
  defp maybe_confirm_plan(_plan, auto_approve: true), do: :ok
  defp maybe_confirm_plan(plan, _opts) do
    IO.puts("\nPlan to be executed:")
    IO.puts(Planner.format_plan(plan))
    
    case IO.gets("\nDo you want to apply this plan? (yes/no): ") do
      "yes\n" -> :ok
      _ -> {:error, :cancelled}
    end
  end
  
  defp maybe_confirm_destroy(_plan, force: true), do: :ok
  defp maybe_confirm_destroy(plan, _opts) do
    IO.puts("\nWARNING: This will DESTROY all infrastructure!")
    IO.puts(Planner.format_plan(plan))
    
    case IO.gets("\nAre you sure you want to destroy everything? Type \"destroy\" to confirm: ") do
      "destroy\n" -> :ok
      _ -> {:error, :cancelled}
    end
  end
end