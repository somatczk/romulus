defmodule Mix.Tasks.Romulus.Health do
  @moduledoc """
  Comprehensive health check for infrastructure components.
  
  This Mix task performs detailed health checks on various infrastructure
  components including VMs, networks, storage pools, and Kubernetes clusters.
  
  ## Usage
  
      mix romulus.health [--format text|json] [--verbose] [--fix]
  
  ## Options
  
    * `--format` or `-f` - Output format: `text` (default) or `json`
    * `--verbose` or `-v` - Enable verbose output with additional details
    * `--fix` - Attempt to automatically fix detected issues where possible
  
  ## Exit Codes
  
    * 0 - All systems healthy
    * 1 - Issues detected or critical failures found
  
  ## Examples
  
      # Basic health check
      mix romulus.health
      
      # JSON output for scripting
      mix romulus.health --format json
      
      # Verbose mode with auto-fix
      mix romulus.health --verbose --fix
  """
  
  use Mix.Task
  require Logger
  
  alias Romulus.Core.{State, Config}
  
  @shortdoc "Check infrastructure health"
  
  @typedoc "Health status levels"
  @type health_status :: :healthy | :degraded | :unhealthy | :critical
  
  @typedoc "Issue severity levels"
  @type issue_level :: :info | :warning | :error | :critical
  
  @typedoc "Issue type identifier"
  @type issue_type :: atom()
  
  @typedoc "Issue detail information"
  @type issue_detail :: String.t() | list() | atom()
  
  @typedoc "Health check issue"
  @type health_issue :: {issue_level(), issue_type(), issue_detail()}
  
  @typedoc "Health check result"
  @type check_result :: {health_status(), [health_issue()]}
  
  @typedoc "System metrics"
  @type metrics :: %{
    total_vms: non_neg_integer(),
    running_vms: non_neg_integer(),
    total_networks: non_neg_integer(),
    active_networks: non_neg_integer(),
    total_pools: non_neg_integer(),
    active_pools: non_neg_integer(),
    total_volumes: non_neg_integer()
  }
  
  defmodule HealthReport do
    @moduledoc """
    Structure for health check report data.
    """
    
    @typedoc "Complete health report structure"
    @type t :: %__MODULE__{
      timestamp: DateTime.t(),
      status: Mix.Tasks.Romulus.Health.health_status(),
      checks: [{atom(), Mix.Tasks.Romulus.Health.health_status()}],
      issues: [Mix.Tasks.Romulus.Health.health_issue()],
      recommendations: [String.t()],
      metrics: Mix.Tasks.Romulus.Health.metrics()
    }
    
    defstruct [
      :timestamp,
      :status,
      :checks,
      :issues,
      :recommendations,
      :metrics
    ]
  end
  
  @doc """
  Main entry point for the health check Mix task.
  
  Parses command line arguments, performs comprehensive health checks,
  optionally attempts to fix issues, and displays the results.
  """
  @spec run([String.t()]) :: :ok
  def run(args) do
    Application.ensure_all_started(:romulus_elixir)
    
    {opts, _, _} = OptionParser.parse(args,
      switches: [format: :string, verbose: :boolean, fix: :boolean],
      aliases: [f: :format, v: :verbose]
    )
    
    format = Keyword.get(opts, :format, "text")
    verbose? = Keyword.get(opts, :verbose, false)
    fix? = Keyword.get(opts, :fix, false)
    
    case perform_health_check(verbose?) do
      {:ok, report} ->
        if fix? && report.status != :healthy do
          Mix.shell().info("[FIX] Attempting to fix detected issues...")
          fix_issues(report.issues)
        end
        
        display_report(report, format)
        
        # Exit with error if unhealthy
        if report.status != :healthy do
          exit({:shutdown, 1})
        end
        
      {:error, reason} ->
        Mix.shell().error("[ERROR] Health check failed: #{reason}")
        exit({:shutdown, 1})
    end
  end
  
  @doc false
  @spec perform_health_check(boolean()) :: {:ok, HealthReport.t()} | {:error, String.t()}
  defp perform_health_check(verbose?) do
    timestamp = DateTime.utc_now()
    checks = []
    issues = []
    
    # Load configuration with proper error handling
    with {:ok, config} <- Romulus.Core.Config.load("romulus.yaml"),
         {:ok, current_state} <- Romulus.Core.State.fetch_current(),
         {:ok, desired_state} <- Romulus.Core.State.from_config(config) do
      # Perform health checks in order of criticality
      {infra_status, infra_issues} = check_infrastructure(current_state, desired_state, verbose?)
      checks = checks ++ [{:infrastructure, infra_status}]
      issues = issues ++ infra_issues
      
      {net_status, net_issues} = check_network(current_state, config, verbose?)
      checks = checks ++ [{:network, net_status}]
      issues = issues ++ net_issues
      
      {storage_status, storage_issues} = check_storage(current_state, verbose?)
      checks = checks ++ [{:storage, storage_status}]
      issues = issues ++ storage_issues
      
      {vm_status, vm_issues} = check_vms(current_state, config, verbose?)
      checks = checks ++ [{:vms, vm_status}]
      issues = issues ++ vm_issues
      
      {k8s_status, k8s_issues} = check_kubernetes(config, verbose?)
      checks = checks ++ [{:kubernetes, k8s_status}]
      issues = issues ++ k8s_issues
      
      # Calculate overall status
      overall_status = calculate_overall_status(checks)
      
      # Generate recommendations
      recommendations = generate_recommendations(issues)
      
      # Collect metrics
      metrics = collect_metrics(current_state)
      
      report = %HealthReport{
        timestamp: timestamp,
        status: overall_status,
        checks: checks,
        issues: issues,
        recommendations: recommendations,
        metrics: metrics
      }
      
      {:ok, report}
    else
      {:error, reason} -> {:error, "Failed to load configuration or state: #{inspect(reason)}"}
    end
  end
  
  @doc false
  @spec calculate_overall_status([{atom(), health_status()}]) :: health_status()
  defp calculate_overall_status(checks) do
    if Enum.all?(checks, fn {_, status} -> status == :healthy end) do
      :healthy
    else
      if Enum.any?(checks, fn {_, status} -> status == :critical end) do
        :critical
      else
        :degraded
      end
    end
  end
  
  @doc false
  @spec check_infrastructure(map(), map(), boolean()) :: check_result()
  defp check_infrastructure(current, desired, verbose?) do
    # Compare current vs desired state
    current_networks = MapSet.new(current.networks, & &1.name)
    desired_networks = MapSet.new(desired.networks, & &1.name)
    
    current_pools = MapSet.new(current.pools, & &1.name)
    desired_pools = MapSet.new(desired.pools, & &1.name)
    
    current_domains = MapSet.new(current.domains, & &1.name)
    desired_domains = MapSet.new(desired.domains, & &1.name)
    
    # Check for missing resources
    missing_networks = MapSet.difference(desired_networks, current_networks)
    missing_pools = MapSet.difference(desired_pools, current_pools)
    missing_domains = MapSet.difference(desired_domains, current_domains)
    
    # Check for extra resources
    extra_networks = MapSet.difference(current_networks, desired_networks)
    extra_domains = MapSet.difference(current_domains, desired_domains)
    
    issues = []
    |> add_missing_resource_issues(missing_networks, :missing_networks)
    |> add_missing_resource_issues(missing_pools, :missing_pools)
    |> add_missing_resource_issues(missing_domains, :missing_domains)
    |> add_extra_resource_issues(extra_networks, :extra_networks, verbose?)
    |> add_extra_resource_issues(extra_domains, :extra_domains, verbose?)
    
    status = cond do
      length(Enum.filter(issues, fn {level, _, _} -> level == :error end)) > 0 -> :unhealthy
      length(issues) > 0 -> :degraded
      true -> :healthy
    end
    
    {status, issues}
  end
  
  defp add_missing_resource_issues(issues, resources, type) do
    if not Enum.empty?(resources) do
      issues ++ [{:error, type, MapSet.to_list(resources)}]
    else
      issues
    end
  end
  
  defp add_extra_resource_issues(issues, resources, type, verbose?) do
    if not Enum.empty?(resources) and verbose? do
      issues ++ [{:warning, type, MapSet.to_list(resources)}]
    else
      issues
    end
  end
  
  @doc false
  @spec check_network(map(), map(), boolean()) :: check_result()
  defp check_network(state, config, _verbose?) do
    # Check if networks are active
    inactive_networks = 
      state.networks
      |> Enum.reject(& &1.active)
      |> Enum.map(& &1.name)
    
    network_issues = Enum.map(inactive_networks, &{:error, :network_inactive, &1})
    
    # Test connectivity to each VM
    nodes = config[:nodes]
    
    master_issues = for i <- 1..nodes[:masters][:count] do
      ip = "#{nodes[:masters][:ip_prefix]}#{i}"
      case System.cmd("ping", ["-c", "1", "-W", "1", ip], stderr_to_stdout: true) do
        {_, 0} -> nil
        _ -> {:warning, :vm_unreachable, "k8s-master-#{i} (#{ip})"}
      end
    end |> Enum.reject(&is_nil/1)
    
    worker_issues = for i <- 1..nodes[:workers][:count] do
      ip = "#{nodes[:workers][:ip_prefix]}#{i}"
      case System.cmd("ping", ["-c", "1", "-W", "1", ip], stderr_to_stdout: true) do
        {_, 0} -> nil
        _ -> {:warning, :vm_unreachable, "k8s-worker-#{i} (#{ip})"}
      end
    end |> Enum.reject(&is_nil/1)
    
    issues = network_issues ++ master_issues ++ worker_issues
    
    status = cond do
      length(Enum.filter(issues, fn {level, _, _} -> level == :error end)) > 0 -> :unhealthy
      length(issues) > 0 -> :degraded
      true -> :healthy
    end
    
    {status, issues}
  end
  
  @doc false
  @spec check_storage(map(), boolean()) :: check_result()
  defp check_storage(state, _verbose?) do
    # Check pool status and capacity
    pool_issues = 
      state.pools
      |> Enum.flat_map(fn pool ->
        active_issue = if not pool.active do
          [{:error, :pool_inactive, pool.name}]
        else
          []
        end
        
        capacity_issue = if pool.capacity && pool.allocation && pool.capacity > 0 do
          usage_percent = (pool.allocation / pool.capacity) * 100
          
          cond do
            usage_percent > 90 ->
              [{:error, :pool_full, "#{pool.name} is #{Float.round(usage_percent, 1)}% full"}]
            usage_percent > 75 ->
              [{:warning, :pool_filling, "#{pool.name} is #{Float.round(usage_percent, 1)}% full"}]
            true ->
              []
          end
        else
          []
        end
        
        active_issue ++ capacity_issue
      end)
    
    # Check disk space on host
    disk_issues = case System.cmd("df", ["-h", "/var/lib/libvirt"], stderr_to_stdout: true) do
      {output, 0} ->
        lines = String.split(output, "\n")
        if length(lines) > 1 do
          parts = lines |> Enum.at(1) |> String.split()
          if length(parts) >= 5 do
            usage = parts |> Enum.at(4) |> String.trim_trailing("%") |> String.to_integer()
            cond do
              usage > 90 -> [{:error, :host_disk_full, "Host disk is #{usage}% full"}]
              usage > 75 -> [{:warning, :host_disk_filling, "Host disk is #{usage}% full"}]
              true -> []
            end
          else
            []
          end
        else
          []
        end
      _ -> 
        [{:warning, :cannot_check_disk, "Unable to check host disk usage"}]
    end
    
    issues = pool_issues ++ disk_issues
    
    status = cond do
      length(Enum.filter(issues, fn {level, _, _} -> level == :error end)) > 0 -> :critical
      length(issues) > 0 -> :degraded
      true -> :healthy
    end
    
    {status, issues}
  end
  
  @doc false
  @spec check_vms(map(), map(), boolean()) :: check_result()
  defp check_vms(state, _config, _verbose?) do
    # Check VM states
    vm_issues = 
      state.domains
      |> Enum.flat_map(fn domain ->
        case domain.state do
          :running -> []
          :paused -> [{:warning, :vm_paused, domain.name}]
          :shut_off -> [{:error, :vm_stopped, domain.name}]
          _ -> [{:warning, :vm_unknown_state, "#{domain.name}: #{domain.state}"}]
        end
      end)
    
    # Check for crashed VMs
    crash_issues = case System.cmd("virsh", ["list", "--all"], stderr_to_stdout: true) do
      {output, 0} ->
        if String.contains?(output, "crashed") do
          [{:critical, :vm_crashed, "One or more VMs have crashed"}]
        else
          []
        end
      _ -> []
    end
    
    issues = vm_issues ++ crash_issues
    
    status = cond do
      Enum.any?(issues, fn {level, _, _} -> level == :critical end) -> :critical
      length(Enum.filter(issues, fn {level, _, _} -> level == :error end)) > 0 -> :unhealthy
      length(issues) > 0 -> :degraded
      true -> :healthy
    end
    
    {status, issues}
  end
  
  @doc false
  @spec check_kubernetes(map(), boolean()) :: check_result()
  defp check_kubernetes(_config, _verbose?) do
    initial_issues = []
    
    # Only check if kubectl is available
    k8s_issues = case System.cmd("which", ["kubectl"], stderr_to_stdout: true) do
      {_, 0} ->
        # Check nodes
        node_issues = case System.cmd("kubectl", ["get", "nodes", "-o", "json"], stderr_to_stdout: true) do
          {output, 0} ->
            case Jason.decode(output) do
              {:ok, %{"items" => nodes}} ->
                Enum.flat_map(nodes, fn node ->
                  name = get_in(node, ["metadata", "name"])
                  conditions = get_in(node, ["status", "conditions"]) || []
                  
                  ready_issue = if (ready = Enum.find(conditions, & &1["type"] == "Ready")) && ready["status"] != "True" do
                    [{:error, :node_not_ready, name}]
                  else
                    []
                  end
                  
                  memory_issue = if (memory = Enum.find(conditions, & &1["type"] == "MemoryPressure")) && memory["status"] == "True" do
                    [{:warning, :memory_pressure, name}]
                  else
                    []
                  end
                  
                  disk_issue = if (disk = Enum.find(conditions, & &1["type"] == "DiskPressure")) && disk["status"] == "True" do
                    [{:warning, :disk_pressure, name}]
                  else
                    []
                  end
                  
                  ready_issue ++ memory_issue ++ disk_issue
                end)
              _ -> []
            end
          _ ->
            [{:error, :kubernetes_unreachable, "Cannot connect to Kubernetes API"}]
        end
        
        # Check critical pods
        pod_issues = case System.cmd("kubectl", ["get", "pods", "-n", "kube-system", "-o", "json"], stderr_to_stdout: true) do
          {output, 0} ->
            case Jason.decode(output) do
              {:ok, %{"items" => pods}} ->
                Enum.flat_map(pods, fn pod ->
                  name = get_in(pod, ["metadata", "name"])
                  phase = get_in(pod, ["status", "phase"])
                  
                  if phase not in ["Running", "Succeeded"] do
                    [{:error, :pod_not_running, "kube-system/#{name}: #{phase}"}]
                  else
                    []
                  end
                end)
              _ -> []
            end
          _ -> []
        end
        
        node_issues ++ pod_issues
      _ ->
        # kubectl not available, skip Kubernetes checks
        []
    end
    
    issues = initial_issues ++ (k8s_issues || [])
    
    status = cond do
      length(Enum.filter(issues, fn {level, _, _} -> level == :error end)) > 0 -> :unhealthy
      length(issues) > 0 -> :degraded
      true -> :healthy
    end
    
    {status, issues}
  end
  
  @doc false
  @spec generate_recommendations([health_issue()]) :: [String.t()]
  defp generate_recommendations(issues) do
    # Generate recommendations based on issues
    issues
    |> Enum.map(fn {level, type, detail} ->
      case {level, type} do
        {:error, :missing_domains} ->
          "Run 'mix romulus.apply' to create missing VMs: #{inspect(detail)}"
        
        {:error, :missing_networks} ->
          "Run 'mix romulus.apply' to create missing networks: #{inspect(detail)}"
        
        {:error, :vm_stopped} ->
          "Start stopped VM: virsh start #{detail}"
        
        {:critical, :vm_crashed} ->
          "Investigate crashed VMs and restart: virsh list --all | grep crashed"
        
        {:error, :pool_full} ->
          "Free up disk space or expand storage pool: #{detail}"
        
        {:error, :host_disk_full} ->
          "URGENT: Free up host disk space immediately"
        
        {:error, :node_not_ready} ->
          "Investigate Kubernetes node: kubectl describe node #{detail}"
        
        {:warning, :vm_unreachable} ->
          "Check network connectivity to: #{detail}"
        
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end
  
  @doc false
  @spec collect_metrics(map()) :: metrics()
  defp collect_metrics(state) do
    %{
      total_vms: length(state.domains),
      running_vms: Enum.count(state.domains, & &1.state == :running),
      total_networks: length(state.networks),
      active_networks: Enum.count(state.networks, & &1.active),
      total_pools: length(state.pools),
      active_pools: Enum.count(state.pools, & &1.active),
      total_volumes: length(state.volumes)
    }
  end
  
  @doc false
  @spec fix_issues([health_issue()]) :: :ok
  defp fix_issues(issues) do
    Enum.each(issues, fn {level, type, detail} ->
      case {level, type} do
        {:error, :vm_stopped} ->
          Mix.shell().info("  [AUTO-FIX] Starting VM: #{detail}")
          case System.cmd("virsh", ["start", detail], stderr_to_stdout: true) do
            {_output, 0} -> Mix.shell().info("    Successfully started #{detail}")
            {error, _} -> Mix.shell().error("    Failed to start #{detail}: #{error}")
          end
          
        {:error, :network_inactive} ->
          Mix.shell().info("  [AUTO-FIX] Starting network: #{detail}")
          case System.cmd("virsh", ["net-start", detail], stderr_to_stdout: true) do
            {_output, 0} -> Mix.shell().info("    Successfully started network #{detail}")
            {error, _} -> Mix.shell().error("    Failed to start network #{detail}: #{error}")
          end
          
        {:error, :pool_inactive} ->
          Mix.shell().info("  [AUTO-FIX] Starting pool: #{detail}")
          case System.cmd("virsh", ["pool-start", detail], stderr_to_stdout: true) do
            {_output, 0} -> Mix.shell().info("    Successfully started pool #{detail}")
            {error, _} -> Mix.shell().error("    Failed to start pool #{detail}: #{error}")
          end
          
        _ ->
          Mix.shell().info("  [SKIP] Cannot auto-fix: #{type} - #{detail}")
      end
    end)
    
    :ok
  end
  
  @doc false
  @spec display_report(HealthReport.t(), String.t()) :: :ok
  defp display_report(report, "json") do
    json = Jason.encode!(%{
      timestamp: report.timestamp,
      status: report.status,
      checks: Enum.map(report.checks, fn {name, status} -> %{name: name, status: status} end),
      issues: Enum.map(report.issues, fn {level, type, detail} -> 
        %{level: level, type: type, detail: detail} 
      end),
      recommendations: report.recommendations,
      metrics: report.metrics
    }, pretty: true)
    
    IO.puts(json)
  end
  
  defp display_report(report, _) do
    status_indicator = case report.status do
      :healthy -> "[HEALTHY]"
      :degraded -> "[DEGRADED]"
      :unhealthy -> "[UNHEALTHY]"
      :critical -> "[CRITICAL]"
    end
    
    Mix.shell().info("\n#{status_indicator} Health Check Report")
    Mix.shell().info("=" |> String.duplicate(60))
    Mix.shell().info("Timestamp: #{report.timestamp}")
    Mix.shell().info("Overall Status: #{report.status}")
    
    Mix.shell().info("\n[CHECKS] Component Status:")
    Enum.each(report.checks, fn {name, status} ->
      indicator = if status == :healthy, do: "[OK]", else: "[FAIL]"
      Mix.shell().info("  #{indicator} #{name}: #{status}")
    end)
    
    if length(report.issues) > 0 do
      Mix.shell().info("\n[ISSUES] Problems Detected:")
      Enum.each(report.issues, fn {level, type, detail} ->
        level_indicator = case level do
          :critical -> "[CRITICAL]"
          :error -> "[ERROR]"
          :warning -> "[WARNING]"
          _ -> "[INFO]"
        end
        Mix.shell().info("  #{level_indicator} #{type}: #{detail}")
      end)
    end
    
    if length(report.recommendations) > 0 do
      Mix.shell().info("\n[RECOMMENDATIONS] Suggested Actions:")
      Enum.each(report.recommendations, fn rec ->
        Mix.shell().info("  - #{rec}")
      end)
    end
    
    Mix.shell().info("\n[METRICS] System Statistics:")
    Mix.shell().info("  VMs: #{report.metrics.running_vms}/#{report.metrics.total_vms} running")
    Mix.shell().info("  Networks: #{report.metrics.active_networks}/#{report.metrics.total_networks} active")
    Mix.shell().info("  Pools: #{report.metrics.active_pools}/#{report.metrics.total_pools} active")
    Mix.shell().info("  Volumes: #{report.metrics.total_volumes} total")
  end
end