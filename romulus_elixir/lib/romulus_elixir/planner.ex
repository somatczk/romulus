defmodule RomulusElixir.Planner do
  @moduledoc """
  Plans infrastructure changes by comparing current and desired states.

  This module implements the planning phase of infrastructure management.
  It compares the current state (what exists in libvirt) with the desired
  state (defined in configuration) and generates a list of actions needed
  to reconcile the difference.

  ## Planning Process

  1. Compare current vs desired resources by type
  2. Identify resources to create, update, or destroy
  3. Generate ordered action list with dependency awareness
  4. Format plan for human review

  ## Resource Types

  The planner handles these libvirt resource types in dependency order:

    * Storage pools - Created first, destroyed last
    * Networks - Created after pools
    * Volumes - Created after pools and networks
    * Domains (VMs) - Created last, destroyed first

  """

  alias RomulusElixir.State

  require Logger
  
  defmodule Action do
    @moduledoc """
    Represents a single infrastructure action in an execution plan.

    Each action describes what operation should be performed on which
    resource and why that operation is needed.
    """

    @enforce_keys [:type, :resource_type, :resource]
    defstruct [:type, :resource_type, :resource, :reason]

    @type action_type :: :create | :update | :destroy
    @type resource_type :: :network | :pool | :volume | :domain

    @type t :: %__MODULE__{
            type: action_type(),
            resource_type: resource_type(),
            resource: struct(),
            reason: String.t() | nil
          }
  end
  
  @doc """
  Creates an execution plan by comparing current and desired states.

  Analyzes the differences between current infrastructure state and
  desired configuration, then generates a list of actions to reconcile
  them. Actions are ordered to respect resource dependencies.

  ## Parameters

    * `current` - Current state from libvirt queries
    * `desired` - Desired state from configuration

  ## Returns

    * `{:ok, actions}` - List of actions to execute
    * `{:error, reason}` - Planning failed

  ## Examples

      iex> current = %State{domains: [], networks: []}
      iex> desired = %State{domains: [domain1], networks: [network1]}
      iex> {:ok, actions} = Planner.create_plan(current, desired)
      iex> length(actions)
      2

  """
  def create_plan(%State{} = current, %State{} = desired) do
    # Plan changes for each resource type in dependency order
    # Dependencies: pools -> networks -> volumes -> domains
    actions =
      []
      |> Kernel.++(plan_pools(current.pools, desired.pools))
      |> Kernel.++(plan_networks(current.networks, desired.networks))
      |> Kernel.++(plan_volumes(current.volumes, desired.volumes))
      |> Kernel.++(plan_domains(current.domains, desired.domains))
    
    {:ok, actions}
  end
  
  @doc """
  Formats an execution plan for human-readable display.

  Takes a list of actions and formats them into a structured text
  representation showing what will be created, updated, or destroyed.

  ## Parameters

    * `actions` - List of Action structs to format

  ## Returns

    * String representation of the plan

  ## Examples

      iex> actions = [%Action{type: :create, resource_type: :domain, resource: domain}]
      iex> Planner.format_plan(actions)
      "Plan Summary:\n...\nTo create:\n  domain: k8s-master-1"

  """
  def format_plan(actions) when is_list(actions) do
    if Enum.empty?(actions) do
      "Infrastructure is up to date. No changes needed."
    else
      lines = ["Plan Summary:", String.duplicate("=", 60)]
      
      grouped = Enum.group_by(actions, & &1.type)
      
      lines = lines ++
        case grouped[:create] do
          creates when is_list(creates) and length(creates) > 0 ->
            ["\nTo create:"] ++ Enum.map(creates, &format_action/1)
          _ -> []
        end ++
        case grouped[:update] do
          updates when is_list(updates) and length(updates) > 0 ->
            ["\nTo update:"] ++ Enum.map(updates, &format_action/1)
          _ -> []
        end ++
        case grouped[:destroy] do
          destroys when is_list(destroys) and length(destroys) > 0 ->
            ["\nTo destroy:"] ++ Enum.map(destroys, &format_action/1)
          _ -> []
        end
      
      lines =
        lines ++
          [
            "\n" <> String.duplicate("=", 60),
            "Total: #{length(actions)} change(s)"
          ]
      
      Enum.join(lines, "\n")
    end
  end
  
  defp format_action(%Action{} = action) do
    prefix = get_resource_prefix(action.resource_type)
    name = extract_resource_name(action.resource)
    "  #{prefix} #{action.resource_type}: #{name}"
  end

  defp get_resource_prefix(resource_type) do
    case resource_type do
      :pool -> "[pool]"
      :network -> "[network]"
      :volume -> "[volume]"
      :domain -> "[domain]"
      _ -> "[resource]"
    end
  end

  defp extract_resource_name(resource) do
    case resource do
      %{name: name} when is_binary(name) -> name
      _ -> "unknown"
    end
  end
  
  # Plans changes for storage pools
  # Pools must be created before volumes and destroyed after volumes
  defp plan_pools(current_pools, desired_pools) do
    plan_resource_changes(
      current_pools,
      desired_pools,
      :pool,
      "Pool does not exist",
      "Pool not in desired state"
    )
  end
  
  # Plans changes for virtual networks
  # Networks must be created after pools and before domains
  defp plan_networks(current_networks, desired_networks) do
    plan_resource_changes(
      current_networks,
      desired_networks,
      :network,
      "Network does not exist",
      "Network not in desired state"
    )
  end
  
  # Plans changes for storage volumes
  # Volumes must be created after pools and before domains
  defp plan_volumes(current_volumes, desired_volumes) do
    plan_resource_changes(
      current_volumes,
      desired_volumes,
      :volume,
      "Volume does not exist",
      "Volume not in desired state"
    )
  end
  
  # Plans changes for virtual machines (domains)
  # Domains must be created last and destroyed first
  defp plan_domains(current_domains, desired_domains) do
    plan_resource_changes(
      current_domains,
      desired_domains,
      :domain,
      "Domain does not exist",
      "Domain not in desired state"
    )
  end

  # Generic resource planning logic used by all resource types
  # Identifies resources to create and destroy based on name comparison
  defp plan_resource_changes(current, desired, resource_type, create_reason, destroy_reason) do
    current_names = extract_resource_names(current)
    desired_names = extract_resource_names(desired)

    resources_to_create = MapSet.difference(desired_names, current_names)
    resources_to_destroy = MapSet.difference(current_names, desired_names)

    create_actions = build_create_actions(desired, resources_to_create, resource_type, create_reason)
    destroy_actions = build_destroy_actions(current, resources_to_destroy, resource_type, destroy_reason)

    create_actions ++ destroy_actions
  end

  # Extracts resource names into a MapSet for efficient set operations
  defp extract_resource_names(resources) do
    resources
    |> Enum.map(fn resource -> resource.name end)
    |> MapSet.new()
  end

  # Builds create actions for resources that don't exist in current state
  defp build_create_actions(desired_resources, names_to_create, resource_type, reason) do
    desired_resources
    |> Enum.filter(fn resource -> resource.name in names_to_create end)
    |> Enum.map(fn resource ->
      %Action{
        type: :create,
        resource_type: resource_type,
        resource: resource,
        reason: reason
      }
    end)
  end

  # Builds destroy actions for resources that exist but are not desired
  defp build_destroy_actions(current_resources, names_to_destroy, resource_type, reason) do
    current_resources
    |> Enum.filter(fn resource -> resource.name in names_to_destroy end)
    |> Enum.map(fn resource ->
      %Action{
        type: :destroy,
        resource_type: resource_type,
        resource: resource,
        reason: reason
      }
    end)
  end
end