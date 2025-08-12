defmodule Mix.Tasks.Romulus.Heal do
  @moduledoc """
  Self-healing capabilities for infrastructure management.
  
  This Mix task provides automated detection and repair of common infrastructure
  issues including VM state problems, network connectivity issues, and storage
  availability problems. It supports dry-run mode for safe planning and can
  operate in automatic or interactive mode.
  
  ## Options
  
    * `--auto` - Run healing automatically without user confirmation
    * `--dry-run` - Show what would be healed without making changes
    * `--scope` - Limit healing scope to: all, vms, network, or storage
  
  ## Examples
  
      # Show what issues would be fixed
      mix romulus.heal --dry-run
      
      # Automatically fix all issues
      mix romulus.heal --auto
      
      # Fix only VM-related issues interactively
      mix romulus.heal --scope vms
  """
  
  use Mix.Task
  require Logger
  
  alias RomulusElixir.{State, Config, Libvirt}
  
  @shortdoc "Auto-heal infrastructure issues"
  
  @type scope :: :all | :vms | :network | :storage
  @type issue_action :: :create | :start | :resume | :cleanup | :remove
  @type issue_type :: :missing_vm | :stopped_vm | :paused_vm | :orphaned_vm |
                      :missing_network | :inactive_network |
                      :missing_pool | :inactive_pool | :pool_full | :missing_volume
  
  @type issue :: %{
    type: issue_type(),
    resource: map(),
    action: issue_action(),
    description: String.t()
  }
  
  @type heal_result :: :ok | {:error, term()}
  
  @valid_scopes [:all, :vms, :network, :storage]
  
  @doc """
  Runs the infrastructure healing task.
  
  Parses command line arguments, detects issues, and either displays a plan
  (dry-run mode) or applies fixes based on user confirmation or auto mode.
  
  ## Arguments
  
    * `args` - Command line arguments list
  
  ## Returns
  
    * `:ok` - Task completed successfully
    * `{:error, reason}` - Task failed with reason
  """
  @spec run([String.t()]) :: :ok | {:error, term()}
  def run(args) do
    with :ok <- Application.ensure_all_started(:romulus_elixir),
         {:ok, opts} <- parse_arguments(args),
         {:ok, scope} <- validate_scope(opts[:scope]),
         {:ok, issues} <- detect_issues(scope) do
      
      Mix.shell().info("[HEAL] Starting infrastructure healing...")
      
      case issues do
        [] ->
          Mix.shell().info("[HEAL] No issues detected. Infrastructure is healthy!")
          :ok
          
        issues when is_list(issues) ->
          Mix.shell().info("[HEAL] Found #{length(issues)} issue(s) to fix")
          
          if opts[:dry_run] do
            Mix.shell().info("\n[HEAL] Dry-run mode - showing what would be fixed:")
            display_healing_plan(issues)
            :ok
          else
            execute_healing(issues, opts[:auto])
          end
      end
    else
      {:error, reason} = error ->
        Mix.shell().error("[HEAL] Failed: #{inspect(reason)}")
        error
    end
  end
  
  # Private helper functions
  
  @spec parse_arguments([String.t()]) :: {:ok, keyword()} | {:error, term()}
  defp parse_arguments(args) do
    try do
      {opts, _, _} = OptionParser.parse(args,
        switches: [auto: :boolean, dry_run: :boolean, scope: :string],
        aliases: [a: :auto, d: :dry_run, s: :scope]
      )
      
      parsed_opts = [
        auto: Keyword.get(opts, :auto, false),
        dry_run: Keyword.get(opts, :dry_run, false),
        scope: Keyword.get(opts, :scope, "all")
      ]
      
      {:ok, parsed_opts}
    rescue
      error -> {:error, {:parse_error, error}}
    end
  end
  
  @spec validate_scope(String.t()) :: {:ok, scope()} | {:error, term()}
  defp validate_scope(scope_str) when is_binary(scope_str) do
    scope = String.to_atom(scope_str)
    if scope in @valid_scopes do
      {:ok, scope}
    else
      {:error, {:invalid_scope, scope_str, @valid_scopes}}
    end
  end
  
  @spec execute_healing([issue()], boolean()) :: :ok | {:error, term()}
  defp execute_healing(issues, auto?) do
    if auto? || confirm_healing(issues) do
      heal_issues(issues)
    else
      Mix.shell().info("[HEAL] Healing cancelled by user")
      :ok
    end
  end
  
  @spec detect_issues(scope()) :: {:ok, [issue()]} | {:error, term()}
  defp detect_issues(scope) do
    with {:ok, config} <- Config.load("romulus.yaml"),
         {:ok, current_state} <- State.fetch_current(),
         {:ok, desired_state} <- State.from_config(config) do
      
      issues = collect_issues_by_scope(scope, current_state, desired_state)
      {:ok, issues}
    else
      {:error, reason} = error ->
        Logger.error("Failed to detect issues: #{inspect(reason)}")
        error
    end
  end
  
  @spec collect_issues_by_scope(scope(), map(), map()) :: [issue()]
  defp collect_issues_by_scope(scope, current_state, desired_state) do
    []
    |> maybe_add_vm_issues(scope, current_state, desired_state)
    |> maybe_add_network_issues(scope, current_state, desired_state)
    |> maybe_add_storage_issues(scope, current_state, desired_state)
  end
  
  @spec maybe_add_vm_issues([issue()], scope(), map(), map()) :: [issue()]
  defp maybe_add_vm_issues(issues, scope, current_state, desired_state) 
       when scope in [:all, :vms] do
    issues ++ detect_vm_issues(current_state, desired_state)
  end
  defp maybe_add_vm_issues(issues, _scope, _current_state, _desired_state), do: issues
  
  @spec maybe_add_network_issues([issue()], scope(), map(), map()) :: [issue()]
  defp maybe_add_network_issues(issues, scope, current_state, desired_state)
       when scope in [:all, :network] do
    issues ++ detect_network_issues(current_state, desired_state)
  end
  defp maybe_add_network_issues(issues, _scope, _current_state, _desired_state), do: issues
  
  @spec maybe_add_storage_issues([issue()], scope(), map(), map()) :: [issue()]
  defp maybe_add_storage_issues(issues, scope, current_state, desired_state)
       when scope in [:all, :storage] do
    issues ++ detect_storage_issues(current_state, desired_state)
  end
  defp maybe_add_storage_issues(issues, _scope, _current_state, _desired_state), do: issues
  
  @spec detect_vm_issues(map(), map()) :: [issue()]
  defp detect_vm_issues(current, desired) do
    # Check for VMs that should be running but aren't
    missing_issues = 
      desired.domains
      |> Enum.filter(&is_map(&1) and Map.has_key?(&1, :name))
      |> Enum.map(fn desired_vm ->
        case find_current_vm(current.domains, desired_vm.name) do
          nil ->
            create_vm_issue(:missing_vm, desired_vm, :create, "VM #{desired_vm.name} is missing")
            
          %{state: :shut_off} = current_vm ->
            create_vm_issue(:stopped_vm, current_vm, :start, "VM #{current_vm.name} is stopped but should be running")
            
          %{state: :paused} = current_vm ->
            create_vm_issue(:paused_vm, current_vm, :resume, "VM #{current_vm.name} is paused and needs to resume")
            
          %{state: :crashed} = current_vm ->
            create_vm_issue(:crashed_vm, current_vm, :restart, "VM #{current_vm.name} has crashed and needs restart")
            
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
    
    # Check for orphaned VMs (safely removable ones)
    orphaned_issues = 
      current.domains
      |> Enum.filter(&is_map(&1) and Map.has_key?(&1, :name))
      |> Enum.filter(fn current_vm ->
        !find_desired_vm?(desired.domains, current_vm.name) &&
        is_safe_to_remove?(current_vm.name)
      end)
      |> Enum.map(fn current_vm ->
        create_vm_issue(
          :orphaned_vm, 
          current_vm, 
          :remove, 
          "VM #{current_vm.name} is orphaned and safe to remove"
        )
      end)
    
    missing_issues ++ orphaned_issues
  rescue
    error ->
      Logger.error("Error detecting VM issues: #{inspect(error)}")
      []
  end
  
  @spec find_current_vm([map()], String.t()) :: map() | nil
  defp find_current_vm(domains, vm_name) when is_list(domains) and is_binary(vm_name) do
    Enum.find(domains, &(is_map(&1) and Map.get(&1, :name) == vm_name))
  end
  defp find_current_vm(_, _), do: nil
  
  @spec find_desired_vm?([map()], String.t()) :: boolean()
  defp find_desired_vm?(domains, vm_name) when is_list(domains) and is_binary(vm_name) do
    Enum.any?(domains, &(is_map(&1) and Map.get(&1, :name) == vm_name))
  end
  defp find_desired_vm?(_, _), do: false
  
  @spec is_safe_to_remove?(String.t()) :: boolean()
  defp is_safe_to_remove?(vm_name) when is_binary(vm_name) do
    safe_prefixes = ["test-", "tmp-", "dev-", "staging-"]
    safe_patterns = ["snapshot", "backup", "temp"]
    
    Enum.any?(safe_prefixes, &String.starts_with?(vm_name, &1)) or
    Enum.any?(safe_patterns, &String.contains?(vm_name, &1))
  end
  defp is_safe_to_remove?(_), do: false
  
  @spec create_vm_issue(issue_type(), map(), issue_action(), String.t()) :: issue()
  defp create_vm_issue(type, resource, action, description) do
    %{
      type: type,
      resource: resource,
      action: action,
      description: description,
      timestamp: DateTime.utc_now(),
      priority: get_issue_priority(type)
    }
  end
  
  @spec get_issue_priority(issue_type()) :: :high | :medium | :low
  defp get_issue_priority(:missing_vm), do: :high
  defp get_issue_priority(:crashed_vm), do: :high
  defp get_issue_priority(:stopped_vm), do: :medium
  defp get_issue_priority(:paused_vm), do: :medium
  defp get_issue_priority(:orphaned_vm), do: :low
  defp get_issue_priority(_), do: :medium
  
  @spec detect_network_issues(map(), map()) :: [issue()]
  defp detect_network_issues(current, desired) do
    desired.networks
    |> Enum.filter(&is_valid_network_config?/1)
    |> Enum.map(fn desired_net ->
      case find_current_network(current.networks, desired_net.name) do
        nil ->
          create_network_issue(
            :missing_network, 
            desired_net, 
            :create, 
            "Network #{desired_net.name} is missing and needs to be created"
          )
          
        %{active: false} = current_net ->
          create_network_issue(
            :inactive_network, 
            current_net, 
            :start, 
            "Network #{current_net.name} is inactive and needs to be started"
          )
          
        %{active: true} = current_net ->
          # Check for configuration drift
          if network_config_differs?(current_net, desired_net) do
            create_network_issue(
              :misconfigured_network,
              current_net,
              :reconfigure,
              "Network #{current_net.name} configuration has drifted"
            )
          else
            nil
          end
          
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  rescue
    error ->
      Logger.error("Error detecting network issues: #{inspect(error)}")
      []
  end
  
  @spec is_valid_network_config?(map()) :: boolean()
  defp is_valid_network_config?(%{name: name}) when is_binary(name), do: true
  defp is_valid_network_config?(_), do: false
  
  @spec find_current_network([map()], String.t()) :: map() | nil
  defp find_current_network(networks, net_name) when is_list(networks) and is_binary(net_name) do
    Enum.find(networks, &(is_map(&1) and Map.get(&1, :name) == net_name))
  end
  defp find_current_network(_, _), do: nil
  
  @spec network_config_differs?(map(), map()) :: boolean()
  defp network_config_differs?(current, desired) do
    # Compare key network configuration parameters
    config_keys = [:bridge, :forward_mode, :dhcp_range, :dns_servers]
    
    Enum.any?(config_keys, fn key ->
      Map.get(current, key) != Map.get(desired, key)
    end)
  end
  
  @spec create_network_issue(issue_type(), map(), issue_action(), String.t()) :: issue()
  defp create_network_issue(type, resource, action, description) do
    %{
      type: type,
      resource: resource,
      action: action,
      description: description,
      timestamp: DateTime.utc_now(),
      priority: get_network_issue_priority(type)
    }
  end
  
  @spec get_network_issue_priority(issue_type()) :: :high | :medium | :low
  defp get_network_issue_priority(:missing_network), do: :high
  defp get_network_issue_priority(:inactive_network), do: :medium
  defp get_network_issue_priority(:misconfigured_network), do: :medium
  defp get_network_issue_priority(_), do: :low
  
  @spec detect_storage_issues(map(), map()) :: [issue()]
  defp detect_storage_issues(current, desired) do
    pool_issues = detect_pool_issues(current.pools, desired.pools)
    volume_issues = detect_volume_issues(current.volumes, desired.volumes)
    
    pool_issues ++ volume_issues
  rescue
    error ->
      Logger.error("Error detecting storage issues: #{inspect(error)}")
      []
  end
  
  @spec detect_pool_issues([map()], [map()]) :: [issue()]
  defp detect_pool_issues(current_pools, desired_pools) do
    desired_pools
    |> Enum.filter(&is_valid_pool_config?/1)
    |> Enum.map(fn desired_pool ->
      case find_current_pool(current_pools, desired_pool.name) do
        nil ->
          create_storage_issue(
            :missing_pool,
            desired_pool,
            :create,
            "Storage pool #{desired_pool.name} is missing and needs to be created"
          )
          
        %{active: false} = current_pool ->
          create_storage_issue(
            :inactive_pool,
            current_pool,
            :start,
            "Storage pool #{current_pool.name} is inactive and needs to be started"
          )
          
        %{allocation: alloc, capacity: cap} = current_pool when is_number(alloc) and is_number(cap) and cap > 0 ->
          usage_ratio = alloc / cap
          cond do
            usage_ratio > 0.95 ->
              create_storage_issue(
                :pool_full,
                current_pool,
                :cleanup,
                "Storage pool #{current_pool.name} is #{Float.round(usage_ratio * 100, 1)}% full and needs cleanup"
              )
              
            usage_ratio > 0.85 ->
              create_storage_issue(
                :pool_warning,
                current_pool,
                :monitor,
                "Storage pool #{current_pool.name} is #{Float.round(usage_ratio * 100, 1)}% full - monitoring recommended"
              )
              
            true -> nil
          end
          
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end
  
  @spec detect_volume_issues([map()], [map()]) :: [issue()]
  defp detect_volume_issues(current_volumes, desired_volumes) do
    desired_volumes
    |> Enum.filter(&is_valid_volume_config?/1)
    |> Enum.filter(fn desired_vol ->
      !find_current_volume?(current_volumes, desired_vol.name)
    end)
    |> Enum.map(fn desired_vol ->
      create_storage_issue(
        :missing_volume,
        desired_vol,
        :create,
        "Volume #{desired_vol.name} is missing and needs to be created"
      )
    end)
  end
  
  @spec is_valid_pool_config?(map()) :: boolean()
  defp is_valid_pool_config?(%{name: name, path: path}) 
       when is_binary(name) and is_binary(path), do: true
  defp is_valid_pool_config?(_), do: false
  
  @spec is_valid_volume_config?(map()) :: boolean()
  defp is_valid_volume_config?(%{name: name}) when is_binary(name), do: true
  defp is_valid_volume_config?(_), do: false
  
  @spec find_current_pool([map()], String.t()) :: map() | nil
  defp find_current_pool(pools, pool_name) when is_list(pools) and is_binary(pool_name) do
    Enum.find(pools, &(is_map(&1) and Map.get(&1, :name) == pool_name))
  end
  defp find_current_pool(_, _), do: nil
  
  @spec find_current_volume?([map()], String.t()) :: boolean()
  defp find_current_volume?(volumes, vol_name) when is_list(volumes) and is_binary(vol_name) do
    Enum.any?(volumes, &(is_map(&1) and Map.get(&1, :name) == vol_name))
  end
  defp find_current_volume?(_, _), do: false
  
  @spec create_storage_issue(issue_type(), map(), issue_action(), String.t()) :: issue()
  defp create_storage_issue(type, resource, action, description) do
    %{
      type: type,
      resource: resource,
      action: action,
      description: description,
      timestamp: DateTime.utc_now(),
      priority: get_storage_issue_priority(type)
    }
  end
  
  @spec get_storage_issue_priority(issue_type()) :: :high | :medium | :low
  defp get_storage_issue_priority(:missing_pool), do: :high
  defp get_storage_issue_priority(:inactive_pool), do: :high
  defp get_storage_issue_priority(:pool_full), do: :high
  defp get_storage_issue_priority(:missing_volume), do: :medium
  defp get_storage_issue_priority(:pool_warning), do: :low
  defp get_storage_issue_priority(_), do: :medium
  
  @spec display_healing_plan([issue()]) :: :ok
  defp display_healing_plan(issues) do
    Mix.shell().info("\n[HEAL] Healing Plan:")
    Mix.shell().info(String.duplicate("=", 80))
    
    # Sort issues by priority and group by action
    sorted_issues = Enum.sort_by(issues, &priority_order(&1.priority))
    grouped = Enum.group_by(sorted_issues, & &1.action)
    
    # Display issues by action type with priority indicators
    display_action_group(grouped[:create], "CREATE", "Resources to create")
    display_action_group(grouped[:start], "START", "Resources to start")
    display_action_group(grouped[:resume], "RESUME", "Resources to resume")
    display_action_group(grouped[:restart], "RESTART", "Resources to restart")
    display_action_group(grouped[:reconfigure], "RECONFIG", "Resources to reconfigure")
    display_action_group(grouped[:cleanup], "CLEANUP", "Resources to cleanup")
    display_action_group(grouped[:monitor], "MONITOR", "Resources to monitor")
    display_action_group(grouped[:remove], "REMOVE", "Resources to remove")
    
    # Display summary
    total_issues = length(issues)
    priority_counts = count_by_priority(issues)
    
    Mix.shell().info("\n[HEAL] Summary:")
    Mix.shell().info("  Total issues: #{total_issues}")
    Mix.shell().info("  High priority: #{priority_counts.high}")
    Mix.shell().info("  Medium priority: #{priority_counts.medium}")
    Mix.shell().info("  Low priority: #{priority_counts.low}")
  end
  
  @spec display_action_group([issue()] | nil, String.t(), String.t()) :: :ok
  defp display_action_group(nil, _action_code, _title), do: :ok
  defp display_action_group([], _action_code, _title), do: :ok
  defp display_action_group(issues, action_code, title) when is_list(issues) do
    Mix.shell().info("\n[#{action_code}] #{title}:")
    
    Enum.each(issues, fn issue ->
      priority_indicator = get_priority_indicator(issue.priority)
      timestamp = format_timestamp(issue.timestamp)
      Mix.shell().info("  #{priority_indicator} #{issue.description} (#{timestamp})")
    end)
  end
  
  @spec priority_order(:high | :medium | :low) :: integer()
  defp priority_order(:high), do: 1
  defp priority_order(:medium), do: 2
  defp priority_order(:low), do: 3
  
  @spec get_priority_indicator(:high | :medium | :low) :: String.t()
  defp get_priority_indicator(:high), do: "[HIGH]"
  defp get_priority_indicator(:medium), do: "[MED] "
  defp get_priority_indicator(:low), do: "[LOW] "
  
  @spec count_by_priority([issue()]) :: %{high: integer(), medium: integer(), low: integer()}
  defp count_by_priority(issues) do
    counts = Enum.group_by(issues, &Map.get(&1, :priority, :medium))
    %{
      high: length(Map.get(counts, :high, [])),
      medium: length(Map.get(counts, :medium, [])),
      low: length(Map.get(counts, :low, []))
    }
  end
  
  @spec format_timestamp(DateTime.t() | nil) :: String.t()
  defp format_timestamp(nil), do: "unknown"
  defp format_timestamp(%DateTime{} = dt) do
    dt |> DateTime.to_time() |> Time.to_string() |> String.slice(0, 8)
  end
  defp format_timestamp(_), do: "unknown"
  
  @spec confirm_healing([issue()]) :: boolean()
  defp confirm_healing(issues) do
    display_healing_plan(issues)
    
    Mix.shell().info("\n[HEAL] This will make changes to your infrastructure.")
    Mix.shell().info("[HEAL] Please review the plan carefully before proceeding.")
    
    response = IO.gets("\n[HEAL] Do you want to proceed with healing? (yes/no): ")
    
    case String.trim(String.downcase(response || "")) do
      answer when answer in ["yes", "y"] -> true
      answer when answer in ["no", "n"] -> false
      _ ->
        Mix.shell().info("[HEAL] Invalid response. Please enter 'yes' or 'no'.")
        confirm_healing(issues)
    end
  rescue
    _ -> false
  end
  
  @spec heal_issues([issue()]) :: :ok | {:error, term()}
  defp heal_issues(issues) do
    Mix.shell().info("\n[HEAL] Applying fixes...")
    
    # Sort by priority (high first) for better healing order
    sorted_issues = Enum.sort_by(issues, &priority_order(&1.priority))
    
    {results, failed_issues} = 
      sorted_issues
      |> Enum.map(&heal_issue_safely/1)
      |> Enum.split_with(&match?({:ok, _}, &1))
    
    successful_count = length(results)
    failed_count = length(failed_issues)
    total_count = successful_count + failed_count
    
    display_healing_results(successful_count, failed_count, total_count)
    
    if failed_count > 0 do
      display_failed_issues(failed_issues)
    end
    
    # Run post-healing verification
    run_post_healing_verification()
    
    if failed_count == 0 do
      :ok
    else
      {:error, {:partial_healing, successful_count, failed_count}}
    end
  end
  
  @spec heal_issue_safely(issue()) :: {:ok, issue()} | {:error, {issue(), term()}}
  defp heal_issue_safely(issue) do
    try do
      case heal_issue(issue) do
        :ok -> {:ok, issue}
        {:error, reason} -> {:error, {issue, reason}}
        error -> {:error, {issue, error}}
      end
    rescue
      error -> {:error, {issue, {:exception, error}}}
    catch
      error -> {:error, {issue, {:thrown, error}}}
    end
  end
  
  @spec display_healing_results(integer(), integer(), integer()) :: :ok
  defp display_healing_results(successful, failed, total) do
    Mix.shell().info("\n[HEAL] Healing Results:")
    Mix.shell().info("  Total issues processed: #{total}")
    Mix.shell().info("  Successfully fixed: #{successful}")
    
    if failed > 0 do
      Mix.shell().info("  Failed to fix: #{failed}")
      success_rate = Float.round(successful / total * 100, 1)
      Mix.shell().info("  Success rate: #{success_rate}%")
    else
      Mix.shell().info("  Success rate: 100%")
    end
  end
  
  @spec display_failed_issues([{:error, {issue(), term()}}]) :: :ok
  defp display_failed_issues(failed_issues) do
    Mix.shell().info("\n[HEAL] Failed Issues:")
    
    Enum.each(failed_issues, fn {:error, {issue, reason}} ->
      Mix.shell().error("  [FAILED] #{issue.description}")
      Mix.shell().error("    Reason: #{format_error_reason(reason)}")
    end)
  end
  
  @spec format_error_reason(term()) :: String.t()
  defp format_error_reason({:exception, %{message: message}}), do: "Exception: #{message}"
  defp format_error_reason({:thrown, reason}), do: "Thrown: #{inspect(reason)}"
  defp format_error_reason(reason) when is_binary(reason), do: reason
  defp format_error_reason(reason), do: inspect(reason)
  
  @spec run_post_healing_verification() :: :ok
  defp run_post_healing_verification() do
    Mix.shell().info("\n[HEAL] Verifying healing results...")
    
    try do
      Mix.Task.run("romulus.health", ["--format", "text", "--quiet"])
    rescue
      _ -> 
        Mix.shell().info("[HEAL] Post-healing verification skipped (health task unavailable)")
    end
    
    :ok
  end
  
  @spec heal_issue(issue()) :: heal_result()
  defp heal_issue(%{action: :create, resource: resource, type: type} = _issue) do
    resource_name = get_resource_name(resource)
    Mix.shell().info("  [CREATE] #{resource_name}...")
    
    with :ok <- validate_create_preconditions(resource, type),
         {:ok, _result} <- create_resource(resource, type) do
      Logger.info("Successfully created #{type}: #{resource_name}")
      :ok
    else
      {:error, reason} = error ->
        Logger.error("Failed to create #{type} #{resource_name}: #{inspect(reason)}")
        error
    end
  end

  # Additional heal_issue clauses grouped together
  defp heal_issue(%{action: :start, resource: resource, type: type}) do
    resource_name = get_resource_name(resource)
    Mix.shell().info("  [START] #{resource_name}...")
    
    with :ok <- validate_start_preconditions(resource, type),
         {:ok, _result} <- start_resource(resource, type) do
      Logger.info("Successfully started #{type}: #{resource_name}")
      :ok
    else
      {:error, reason} = error ->
        Logger.error("Failed to start #{type} #{resource_name}: #{inspect(reason)}")
        error
    end
  end

  defp heal_issue(%{action: :resume, resource: %{name: name}}) do
    Mix.shell().info("  [RESUME] #{name}...")
    
    case System.cmd("virsh", ["resume", name]) do
      {_, 0} -> 
        Logger.info("Successfully resumed VM: #{name}")
        :ok
      {output, code} -> 
        Logger.error("Failed to resume VM #{name}: #{String.trim(output)}")
        {:error, {:virsh_failed, code, String.trim(output)}}
    end
  end

  defp heal_issue(%{action: :restart, resource: %{name: name}}) do
    Mix.shell().info("  [RESTART] #{name}...")
    
    with {_, 0} <- System.cmd("virsh", ["destroy", name]),
         Process.sleep(2000),
         {_, 0} <- System.cmd("virsh", ["start", name]) do
      Logger.info("Successfully restarted VM: #{name}")
      :ok
    else
      error ->
        Logger.error("Failed to restart VM #{name}: #{inspect(error)}")
        error
    end
  end

  defp heal_issue(%{action: :remove, resource: %{name: name}, type: :orphaned_vm}) do
    Mix.shell().info("  [REMOVE] Orphaned VM #{name}...")
    
    # Enhanced safety checks before removal
    with :ok <- validate_safe_removal(name),
         :ok <- graceful_vm_shutdown(name),
         {:ok, _} <- remove_vm_safely(name) do
      Logger.info("Successfully removed orphaned VM: #{name}")
      :ok
    else
      {:error, :not_safe_to_remove} ->
        Mix.shell().info("    [SKIP] #{name} requires manual review before removal")
        Logger.warning("Skipped removal of VM #{name} - manual review required")
        :ok
      {:error, reason} = error ->
        Logger.error("Failed to remove VM #{name}: #{inspect(reason)}")
        error
    end
  end

  defp heal_issue(%{action: :cleanup, resource: %{name: pool_name}}) do
    Mix.shell().info("  [CLEANUP] Storage pool #{pool_name}...")
    
    with {:ok, volumes} <- Libvirt.list_volumes(pool_name),
         cleanup_results <- Enum.map(volumes, &cleanup_volume(&1, pool_name)) do
      
      successful_cleanups = Enum.count(cleanup_results, &(&1 == :ok))
      Mix.shell().info("    Cleaned up #{successful_cleanups} volumes from #{pool_name}")
      
      Logger.info("Storage cleanup completed for pool: #{pool_name}")
      :ok
    else
      {:error, reason} = error ->
        Logger.error("Failed to cleanup storage pool #{pool_name}: #{inspect(reason)}")
        error
    end
  end

  defp heal_issue(%{action: action, resource: resource}) do
    resource_name = get_resource_name(resource)
    Logger.warning("Unknown healing action #{action} for resource #{resource_name}")
    {:error, {:unknown_action, action}}
  end
  
  @spec validate_create_preconditions(map(), issue_type()) :: :ok | {:error, term()}
  defp validate_create_preconditions(resource, _type) do
    case get_resource_name(resource) do
      name when is_binary(name) and byte_size(name) > 0 -> :ok
      _ -> {:error, :invalid_resource_name}
    end
  end
  
  @spec create_resource(map(), issue_type()) :: {:ok, term()} | {:error, term()}
  defp create_resource(resource, type) do
    case {resource, type} do
      {%{__struct__: Libvirt.Network}, _} -> 
        Libvirt.create_network(resource)
      {%{__struct__: Libvirt.Pool}, _} -> 
        Libvirt.create_pool(resource)
      {%{__struct__: Libvirt.Volume}, _} -> 
        Libvirt.create_volume(resource)
      {%{__struct__: Libvirt.Domain}, _} -> 
        Libvirt.create_domain(resource)
      {_, :missing_network} ->
        create_network_from_config(resource)
      {_, :missing_pool} ->
        create_pool_from_config(resource)
      {_, :missing_volume} ->
        create_volume_from_config(resource)
      {_, :missing_vm} ->
        create_vm_from_config(resource)
      _ -> 
        {:error, {:unknown_resource_type, type}}
    end
  end
  
  @spec create_network_from_config(map()) :: {:ok, term()} | {:error, term()}
  defp create_network_from_config(%{name: name} = config) do
    # Create network using virsh command as fallback
    xml_config = generate_network_xml(config)
    
    with {:ok, xml_file} <- write_temp_xml(xml_config, "network_#{name}"),
         {_, 0} <- System.cmd("virsh", ["net-define", xml_file]),
         {_, 0} <- System.cmd("virsh", ["net-start", name]) do
      File.rm(xml_file)
      {:ok, :created}
    else
      {output, code} ->
        {:error, {:virsh_failed, code, output}}
      error ->
        error
    end
  end
  
  @spec create_pool_from_config(map()) :: {:ok, term()} | {:error, term()}
  defp create_pool_from_config(%{name: name, path: path} = config) do
    # Ensure directory exists
    with :ok <- File.mkdir_p(path),
         xml_config <- generate_pool_xml(config),
         {:ok, xml_file} <- write_temp_xml(xml_config, "pool_#{name}"),
         {_, 0} <- System.cmd("virsh", ["pool-define", xml_file]),
         {_, 0} <- System.cmd("virsh", ["pool-start", name]) do
      File.rm(xml_file)
      {:ok, :created}
    else
      {output, code} ->
        {:error, {:virsh_failed, code, output}}
      error ->
        error
    end
  end
  
  @spec create_volume_from_config(map()) :: {:ok, term()}
  defp create_volume_from_config(%{name: name, pool: pool, size: size}) do
    case System.cmd("virsh", ["vol-create-as", pool, name, size]) do
      {_, 0} -> {:ok, :created}
      {output, code} -> {:error, {:virsh_failed, code, output}}
    end
  end
  
  @spec create_vm_from_config(map()) :: {:ok, term()} | {:error, term()}
  defp create_vm_from_config(%{name: name} = config) do
    xml_config = generate_vm_xml(config)
    
    with {:ok, xml_file} <- write_temp_xml(xml_config, "vm_#{name}"),
         {_, 0} <- System.cmd("virsh", ["define", xml_file]),
         {_, 0} <- System.cmd("virsh", ["start", name]) do
      File.rm(xml_file)
      {:ok, :created}
    else
      {output, code} ->
        {:error, {:virsh_failed, code, output}}
      error ->
        error
    end
  end
  
  @spec validate_start_preconditions(map(), issue_type()) :: :ok | {:error, term()}
  defp validate_start_preconditions(%{name: name}, _type) when is_binary(name), do: :ok
  defp validate_start_preconditions(_, _), do: {:error, :invalid_resource}
  
  @spec start_resource(map(), issue_type()) :: {:ok, term()} | {:error, term()}
  defp start_resource(%{name: name} = resource, type) do
    case type do
      t when t in [:stopped_vm, :crashed_vm] ->
        start_domain(name)
      :inactive_network ->
        start_network(name)
      :inactive_pool ->
        start_pool(name)
      _ ->
        # Auto-detect resource type
        cond do
          Map.has_key?(resource, :vcpu) -> start_domain(name)
          Map.has_key?(resource, :mode) -> start_network(name)
          Map.has_key?(resource, :path) -> start_pool(name)
          true -> {:error, {:unknown_resource_type, type}}
        end
    end
  end
  
  @spec start_domain(String.t()) :: {:ok, term()} | {:error, term()}
  defp start_domain(name) do
    case System.cmd("virsh", ["start", name]) do
      {_, 0} -> {:ok, :started}
      {output, code} -> {:error, {:virsh_failed, code, String.trim(output)}}
    end
  end
  
  @spec start_network(String.t()) :: {:ok, term()} | {:error, term()}
  defp start_network(name) do
    case System.cmd("virsh", ["net-start", name]) do
      {_, 0} -> {:ok, :started}
      {output, code} -> {:error, {:virsh_failed, code, String.trim(output)}}
    end
  end
  
  @spec start_pool(String.t()) :: {:ok, term()} | {:error, term()}
  defp start_pool(name) do
    case System.cmd("virsh", ["pool-start", name]) do
      {_, 0} -> {:ok, :started}
      {output, code} -> {:error, {:virsh_failed, code, String.trim(output)}}
    end
  end
  
  @spec cleanup_volume(map(), String.t()) :: :ok | {:error, term()}
  defp cleanup_volume(%{name: volume_name} = _volume, pool_name) do
    Mix.shell().info("    Removing volume: #{volume_name}")
    
    case Libvirt.delete_volume(volume_name, pool_name) do
      :ok ->
        Logger.info("Removed volume #{volume_name} from pool #{pool_name}")
        :ok
      {:error, reason} = error ->
        Logger.error("Failed to remove volume #{volume_name}: #{inspect(reason)}")
        error
    end
  end
  
  @spec validate_safe_removal(String.t()) :: :ok | {:error, :not_safe_to_remove}
  defp validate_safe_removal(vm_name) do
    if is_safe_to_remove?(vm_name) do
      # Additional runtime checks
      case System.cmd("virsh", ["domstate", vm_name]) do
        {state, 0} when state in ["shut off\n", "crashed\n"] ->
          :ok
        {"running\n", 0} ->
          # Only remove running VMs if they match safe patterns
          if String.contains?(vm_name, "test") or String.contains?(vm_name, "tmp") do
            :ok
          else
            {:error, :not_safe_to_remove}
          end
        _ ->
          {:error, :not_safe_to_remove}
      end
    else
      {:error, :not_safe_to_remove}
    end
  end
  
  @spec graceful_vm_shutdown(String.t()) :: :ok | {:error, term()}
  defp graceful_vm_shutdown(vm_name) do
    case System.cmd("virsh", ["domstate", vm_name]) do
      {"running\n", 0} ->
        Mix.shell().info("    Gracefully shutting down #{vm_name}...")
        case System.cmd("virsh", ["shutdown", vm_name]) do
          {_, 0} ->
            # Wait up to 30 seconds for graceful shutdown
            wait_for_shutdown(vm_name, 30)
          {output, code} ->
            {:error, {:shutdown_failed, code, String.trim(output)}}
        end
      _ ->
        :ok  # VM already stopped
    end
  end
  
  @spec wait_for_shutdown(String.t(), integer()) :: :ok | {:error, :shutdown_timeout}
  defp wait_for_shutdown(_vm_name, 0), do: {:error, :shutdown_timeout}
  defp wait_for_shutdown(vm_name, retries) when retries > 0 do
    case System.cmd("virsh", ["domstate", vm_name]) do
      {"shut off\n", 0} -> :ok
      _ ->
        :timer.sleep(1000)
        wait_for_shutdown(vm_name, retries - 1)
    end
  end
  
  @spec remove_vm_safely(String.t()) :: {:ok, term()} | {:error, term()}
  defp remove_vm_safely(vm_name) do
    # Force stop if still running
    case System.cmd("virsh", ["destroy", vm_name]) do
      {_, 0} -> :ok
      {_, code} when code != 0 -> :ok  # May already be stopped
    end
    
    # Undefine the domain
    case System.cmd("virsh", ["undefine", vm_name, "--remove-all-storage"]) do
      {_, 0} -> {:ok, :removed}
      {output, code} -> {:error, {:undefine_failed, code, String.trim(output)}}
    end
  end
  
  # Utility functions for resource management
  
  @spec get_resource_name(map()) :: String.t()
  defp get_resource_name(%{name: name}) when is_binary(name), do: name
  defp get_resource_name(resource), do: "unknown_#{inspect(resource)}"
  
  @spec write_temp_xml(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp write_temp_xml(xml_content, prefix) do
    temp_file = Path.join(System.tmp_dir!(), "#{prefix}_#{:rand.uniform(10000)}.xml")
    
    case File.write(temp_file, xml_content) do
      :ok -> {:ok, temp_file}
      error -> error
    end
  end
  
  @spec generate_network_xml(map()) :: String.t()
  defp generate_network_xml(%{name: name} = config) do
    bridge_name = Map.get(config, :bridge, "br-#{name}")
    forward_mode = Map.get(config, :forward_mode, "nat")
    
    """
    <network>
      <name>#{name}</name>
      <forward mode="#{forward_mode}"/>
      <bridge name="#{bridge_name}" stp="on" delay="0"/>
      <ip address="192.168.#{:rand.uniform(254)}.1" netmask="255.255.255.0">
        <dhcp>
          <range start="192.168.#{:rand.uniform(254)}.10" end="192.168.#{:rand.uniform(254)}.100"/>
        </dhcp>
      </ip>
    </network>
    """
  end
  
  @spec generate_pool_xml(map()) :: String.t()
  defp generate_pool_xml(%{name: name, path: path}) do
    """
    <pool type="dir">
      <name>#{name}</name>
      <target>
        <path>#{path}</path>
      </target>
    </pool>
    """
  end
  
  @spec generate_vm_xml(map()) :: String.t()
  defp generate_vm_xml(%{name: name} = config) do
    memory = Map.get(config, :memory, "1048576")  # 1GB default
    vcpu = Map.get(config, :vcpu, "1")
    
    """
    <domain type="kvm">
      <name>#{name}</name>
      <memory unit="KiB">#{memory}</memory>
      <vcpu placement="static">#{vcpu}</vcpu>
      <os>
        <type arch="x86_64" machine="pc-q35-6.2">hvm</type>
        <boot dev="hd"/>
      </os>
      <devices>
        <emulator>/usr/bin/qemu-system-x86_64</emulator>
        <interface type="network">
          <source network="default"/>
          <model type="virtio"/>
        </interface>
        <console type="pty">
          <target type="serial" port="0"/>
        </console>
      </devices>
    </domain>
    """
  end
  
end