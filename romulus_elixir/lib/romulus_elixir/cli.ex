defmodule RomulusElixir.CLI do
  @moduledoc """
  Command-line interface for Romulus infrastructure operations.

  This module provides the CLI entry points for all Romulus operations.
  It handles user interaction, environment variable processing, and
  proper exit codes for shell integration.

  ## Environment Variables

    * `ROMULUS_AUTO_APPROVE` - Skip apply confirmations when set to "true"
    * `ROMULUS_FORCE` - Skip destroy confirmations when set to "true"

  """

  alias RomulusElixir

  require Logger

  @type exit_code :: 0 | 1
  
  @doc """
  Executes the plan command and outputs the execution plan.

  Generates and displays an infrastructure plan showing what changes
  would be made without actually applying them.

  ## Exit Codes

    * 0 - Plan generated successfully
    * 1 - Error occurred during planning

  """
  @spec plan() :: exit_code()
  def plan do
    IO.puts("\nGenerating infrastructure plan...\n")
    
    case RomulusElixir.plan() do
      {:ok, plan} ->
        IO.puts(RomulusElixir.Planner.format_plan(plan))
        System.halt(0)
        
      {:error, reason} ->
        IO.puts("Error: #{inspect(reason)}")
        System.halt(1)
    end
  end
  
  @doc """
  Executes the apply command to provision infrastructure.

  Generates and applies an infrastructure plan. Respects the
  ROMULUS_AUTO_APPROVE environment variable to skip confirmations.

  ## Exit Codes

    * 0 - Changes applied successfully or cancelled by user
    * 1 - Error occurred during application

  """
  @spec apply() :: exit_code()
  def apply do
    IO.puts("\nApplying infrastructure changes...\n")
    
    # Check for auto-approve flag
    auto_approve = System.get_env("ROMULUS_AUTO_APPROVE") == "true"
    
    case RomulusElixir.apply(nil, auto_approve: auto_approve) do
      {:ok, _result} ->
        IO.puts("\n Infrastructure applied successfully!")
        System.halt(0)
        
      {:error, :cancelled} ->
        IO.puts("\nApply cancelled by user.")
        System.halt(0)
        
      {:error, reason} ->
        IO.puts("\nError: #{inspect(reason)}")
        System.halt(1)
    end
  end
  
  @doc """
  Executes the destroy command to remove all infrastructure.

  Destroys all managed infrastructure resources. Respects the
  ROMULUS_FORCE environment variable to skip confirmations.

  ## Exit Codes

    * 0 - Infrastructure destroyed successfully or cancelled by user
    * 1 - Error occurred during destruction

  """
  @spec destroy() :: exit_code()
  def destroy do
    IO.puts("\nPreparing to destroy infrastructure...\n")
    
    # Check for force flag
    force = System.get_env("ROMULUS_FORCE") == "true"
    
    case RomulusElixir.destroy(nil, force: force) do
      {:ok, _result} ->
        IO.puts("\n Infrastructure destroyed successfully!")
        System.halt(0)
        
      {:error, :cancelled} ->
        IO.puts("\nDestroy cancelled by user.")
        System.halt(0)
        
      {:error, reason} ->
        IO.puts("\nError: #{inspect(reason)}")
        System.halt(1)
    end
  end
  
  @doc """
  Renders and validates cloud-init templates.

  Processes all cloud-init templates with configuration variables
  and displays the rendered output for validation.

  ## Exit Codes

    * 0 - Templates rendered successfully
    * 1 - Error occurred during rendering

  """
  @spec render_cloudinit() :: exit_code()
  def render_cloudinit do
    IO.puts("\nRendering cloud-init templates...\n")
    
    case RomulusElixir.render_cloudinit() do
      {:ok, results} ->
        IO.puts(" Cloud-init templates rendered successfully!")
        IO.inspect(results, pretty: true)
        System.halt(0)
        
      {:error, reason} ->
        IO.puts("Error: #{inspect(reason)}")
        System.halt(1)
    end
  end
  
  @doc """
  Bootstraps a Kubernetes cluster on provisioned infrastructure.

  Initializes the Kubernetes cluster including master setup,
  worker node joining, and CNI configuration.

  ## Exit Codes

    * 0 - Cluster bootstrapped successfully
    * 1 - Error occurred during bootstrapping

  """
  @spec bootstrap_k8s() :: exit_code()
  def bootstrap_k8s do
    IO.puts("\nBootstrapping Kubernetes cluster...\n")
    
    case RomulusElixir.bootstrap_k8s() do
      {:ok, _result} ->
        IO.puts("\n Kubernetes cluster bootstrapped successfully!")
        System.halt(0)
        
      {:error, reason} ->
        IO.puts("\nError: #{inspect(reason)}")
        System.halt(1)
    end
  end
end