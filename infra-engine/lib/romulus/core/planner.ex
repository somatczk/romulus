defmodule Romulus.Core.Planner do
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

  alias Romulus.Core.{Config, State}
  alias Romulus.Error

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
    
    # Validate consistency before returning the plan
    case validate_plan_consistency(current, desired, actions) do
      :ok -> {:ok, actions}
      {:error, reason} -> {:error, reason}
    end
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
  # Identifies resources to create, update, and destroy based on comparison
  defp plan_resource_changes(current, desired, resource_type, create_reason, destroy_reason) do
    current_names = extract_resource_names(current)
    desired_names = extract_resource_names(desired)

    resources_to_create = MapSet.difference(desired_names, current_names)
    resources_to_destroy = MapSet.difference(current_names, desired_names)
    
    # Find resources that exist in both but may need updates
    common_resources = MapSet.intersection(current_names, desired_names)
    resources_to_update = find_resources_needing_updates(current, desired, common_resources)

    create_actions = build_create_actions(desired, resources_to_create, resource_type, create_reason)
    update_actions = build_update_actions(desired, resources_to_update, resource_type, "Resource configuration changed")
    destroy_actions = build_destroy_actions(current, resources_to_destroy, resource_type, destroy_reason)

    create_actions ++ update_actions ++ destroy_actions
  end

  # Extracts resource names into a MapSet for efficient set operations
  defp extract_resource_names(resources) do
    resources
    |> Enum.map(fn resource -> resource.name end)
    |> Enum.filter(& &1 != nil)  # Filter out nil names
    |> MapSet.new()
  end

  # Builds create actions for resources that don't exist in current state
  defp build_create_actions(desired_resources, names_to_create, resource_type, reason) do
    desired_resources
    |> Enum.filter(fn resource -> 
      resource.name in names_to_create or resource.name == nil
    end)
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
    |> Enum.filter(fn resource -> 
      resource.name in names_to_destroy or resource.name == nil
    end)
    |> Enum.map(fn resource ->
      %Action{
        type: :destroy,
        resource_type: resource_type,
        resource: resource,
        reason: reason
      }
    end)
  end
  
  # Finds resources that need updates by comparing current and desired configurations
  defp find_resources_needing_updates(current, desired, common_names) do
    # Handle potential duplicate names by taking the first resource for each name
    current_by_name = current
    |> Enum.group_by(& &1.name)
    |> Enum.map(fn {name, resources} -> {name, hd(resources)} end)
    |> Enum.into(%{})
    
    desired_by_name = desired
    |> Enum.group_by(& &1.name)
    |> Enum.map(fn {name, resources} -> {name, hd(resources)} end)
    |> Enum.into(%{})
    
    Enum.filter(common_names, fn name ->
      current_resource = Map.get(current_by_name, name)
      desired_resource = Map.get(desired_by_name, name)
      
      current_resource && desired_resource && resources_different?(current_resource, desired_resource)
    end)
    |> MapSet.new()
  end
  
  # Builds update actions for resources that need configuration changes
  defp build_update_actions(desired_resources, names_to_update, resource_type, reason) do
    desired_resources
    |> Enum.filter(fn resource -> resource.name in names_to_update end)
    |> Enum.map(fn resource ->
      %Action{
        type: :update,
        resource_type: resource_type,
        resource: resource,
        reason: reason
      }
    end)
  end
  
  # Compares two resources to determine if they need updates
  defp resources_different?(current, desired) do
    # Simple comparison - for now, compare all accessible fields except name
    current_map = Map.from_struct(current) |> Map.delete(:name) |> Map.delete(:uuid)
    desired_map = Map.from_struct(desired) |> Map.delete(:name) |> Map.delete(:uuid)
    
    current_map != desired_map
  end
  
  @doc """
  Validate a plan for consistency and proper ordering.
  """
  def validate_plan(actions) when is_list(actions) do
    with :ok <- validate_dependency_order(actions),
         :ok <- validate_resource_references(actions) do
      {:ok, actions}
    end
  end
  
  @doc """
  Optimize a plan by removing redundant actions and enabling parallelization.
  """
  def optimize_plan(actions) when is_list(actions) do
    actions
    |> remove_redundant_actions()
    |> sort_by_dependencies()
  end
  
  @doc """
  Get plan statistics for analysis.
  """
  def get_plan_statistics(actions) when is_list(actions) do
    action_counts = Enum.group_by(actions, & &1.type) |> Enum.map(fn {type, acts} -> {type, length(acts)} end) |> Enum.into(%{})
    resource_counts = Enum.group_by(actions, & &1.resource_type) |> Enum.map(fn {type, acts} -> {type, length(acts)} end) |> Enum.into(%{})
    
    %{
      total_actions: length(actions),
      by_action_type: action_counts,
      by_resource_type: resource_counts,
      estimated_duration_minutes: estimate_execution_time(actions)
    }
  end
  
  # Private validation functions
  
  defp validate_dependency_order(actions) do
    # Check that pools come before volumes, volumes before domains, etc.
    resource_positions = actions
    |> Enum.with_index()
    |> Enum.group_by(fn {action, _} -> action.resource_type end, fn {_, index} -> index end)
    
    _pool_positions = Map.get(resource_positions, :pool, [])
    _network_positions = Map.get(resource_positions, :network, [])
    _volume_positions = Map.get(resource_positions, :volume, [])
    _domain_positions = Map.get(resource_positions, :domain, [])
    
    # For create actions, pools should come before volumes, volumes before domains
    create_actions = actions
    |> Enum.with_index()
    |> Enum.filter(fn {action, _} -> action.type == :create end)
    |> Enum.map(fn {action, index} -> {action.resource_type, index} end)
    
    create_pools = create_actions |> Enum.filter(fn {type, _} -> type == :pool end) |> Enum.map(fn {_, index} -> index end)
    create_volumes = create_actions |> Enum.filter(fn {type, _} -> type == :volume end) |> Enum.map(fn {_, index} -> index end)
    create_domains = create_actions |> Enum.filter(fn {type, _} -> type == :domain end) |> Enum.map(fn {_, index} -> index end)
    
    cond do
      Enum.any?(create_volumes, fn vol_idx -> Enum.any?(create_pools, fn pool_idx -> vol_idx < pool_idx end) end) ->
        {:error, "Volumes cannot be created before pools"}
      Enum.any?(create_domains, fn dom_idx -> Enum.any?(create_volumes, fn vol_idx -> dom_idx < vol_idx end) end) ->
        {:error, "Domains cannot be created before volumes"}
      true ->
        :ok
    end
  end
  
  defp validate_resource_references(actions) do
    # Check that referenced resources exist in the plan
    # For simplicity, just validate that volume actions reference existing pools
    volume_actions = Enum.filter(actions, & &1.resource_type == :volume)
    pool_names = actions
    |> Enum.filter(& &1.resource_type == :pool)
    |> Enum.map(& &1.resource.name)
    |> MapSet.new()
    
    invalid_volume = Enum.find(volume_actions, fn action ->
      action.resource.pool && action.resource.pool not in pool_names
    end)
    
    case invalid_volume do
      nil -> :ok
      action -> {:error, "Volume '#{action.resource.name}' references non-existent pool '#{action.resource.pool}'"}
    end
  end
  
  defp remove_redundant_actions(actions) do
    # Remove create/destroy pairs for the same resource
    grouped = Enum.group_by(actions, fn action -> {action.resource_type, action.resource.name} end)
    
    Enum.flat_map(grouped, fn {_key, resource_actions} ->
      case resource_actions do
        [create, destroy] when create.type == :create and destroy.type == :destroy ->
          # Cancel out create/destroy pairs
          []
        [destroy, create] when create.type == :create and destroy.type == :destroy ->
          []
        actions ->
          actions
      end
    end)
  end
  
  defp sort_by_dependencies(actions) do
    # Sort actions to respect dependencies
    Enum.sort(actions, &dependency_compare/2)
  end
  
  defp dependency_compare(action1, action2) do
    type_priority = %{pool: 1, network: 2, volume: 3, domain: 4}
    
    cond do
      action1.type == :create and action2.type == :destroy ->
        true
      action1.type == :destroy and action2.type == :create ->
        false
      action1.type == action2.type ->
        Map.get(type_priority, action1.resource_type, 5) <= Map.get(type_priority, action2.resource_type, 5)
      true ->
        true
    end
  end
  
  defp validate_plan_consistency(current, desired, actions) do
    # Check for orphaned resources - domains referencing non-existent pools/networks
    domain_actions = Enum.filter(actions, & &1.resource_type == :domain)
    network_names = current.networks ++ desired.networks |> Enum.map(& &1.name) |> MapSet.new()
    pool_names = current.pools ++ desired.pools |> Enum.map(& &1.name) |> MapSet.new()
    
    orphaned = Enum.find(domain_actions, fn action ->
      domain = action.resource
      (domain.network && domain.network not in network_names) ||
      (domain.pool && domain.pool not in pool_names)
    end)
    
    case orphaned do
      nil -> :ok
      action -> {:error, "Domain #{action.resource.name} references non-existent dependencies"}
    end
  end
  
  defp estimate_execution_time(actions) do
    # Rough estimates in minutes
    action_durations = %{
      {:create, :pool} => 1,
      {:create, :network} => 1,
      {:create, :volume} => 5,
      {:create, :domain} => 3,
      {:destroy, :pool} => 1,
      {:destroy, :network} => 1,
      {:destroy, :volume} => 2,
      {:destroy, :domain} => 2
    }
    
    total_duration = Enum.reduce(actions, 0, fn action, acc ->
      duration = Map.get(action_durations, {action.type, action.resource_type}, 1)
      acc + duration
    end)
    
    # Assume some parallelization for independent actions
    max(total_duration * 0.6, 1.0) |> Float.round(1)
  end
end
