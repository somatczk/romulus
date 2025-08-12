defmodule Romulus.Planner do
  @moduledoc """
  Plans infrastructure changes by comparing desired state with current state.
  Generates ordered list of actions to achieve desired state.
  """

  require Logger
  alias Romulus.State.Schema.{ClusterConfig, VM, Network, Pool, Volume}

  defmodule Action do
    @type action_type :: :create | :update | :destroy | :noop
    @type resource_type :: :pool | :network | :volume | :domain | :cloudinit

    defstruct [:type, :resource_type, :resource, :reason]

    @type t :: %__MODULE__{
            type: action_type(),
            resource_type: resource_type(),
            resource: any(),
            reason: String.t()
          }
  end

  @doc """
  Creates a plan by comparing desired state with current state
  """
  def create_plan(%ClusterConfig{} = config) do
    Logger.info("Creating infrastructure plan...")

    with {:ok, current_state} <- get_current_state(),
         desired_state <- generate_desired_state(config),
         actions <- compute_actions(current_state, desired_state) do
      {:ok, actions}
    end
  end

  @doc """
  Gets the current infrastructure state from libvirt
  """
  def get_current_state do
    adapter = get_adapter()

    with {:ok, pools} <- adapter.list_pools(),
         {:ok, networks} <- adapter.list_networks(),
         {:ok, domains} <- adapter.list_domains() do
      volumes =
        Enum.flat_map(pools, fn pool ->
          case adapter.list_volumes(pool) do
            {:ok, vols} -> Enum.map(vols, &{pool, &1})
            _ -> []
          end
        end)

      {:ok,
       %{
         pools: pools,
         networks: networks,
         domains: domains,
         volumes: volumes
       }}
    end
  end

  @doc """
  Generates desired state from configuration
  """
  def generate_desired_state(%ClusterConfig{} = config) do
    pool = %Pool{
      name: "k8s-cluster-pool",
      type: "dir",
      path: config.pool_path
    }

    network = %Network{
      name: "k8s-network",
      mode: "nat",
      domain: "k8s.local",
      addresses: [config.network_cidr],
      dns_enabled: true,
      dhcp_enabled: true
    }

    base_volume = %Volume{
      name: "debian-12-base",
      pool: pool.name,
      format: "qcow2",
      source: config.base_image_url,
      size: 10_737_418_240  # 10GB base
    }

    # Generate master VMs
    masters =
      for i <- 1..config.master_count do
        %VM{
          name: "k8s-master-#{i}",
          type: :master,
          memory: config.master_memory,
          vcpu: config.master_vcpu,
          disk_size: config.master_disk_size,
          ip: "10.10.10.1#{i}",
          pool: pool.name,
          network: network.name
        }
      end

    # Generate worker VMs
    workers =
      for i <- 1..config.worker_count do
        %VM{
          name: "k8s-worker-#{i}",
          type: :worker,
          memory: config.worker_memory,
          vcpu: config.worker_vcpu,
          disk_size: config.worker_disk_size,
          ip: "10.10.10.2#{i}",
          pool: pool.name,
          network: network.name
        }
      end

    # Generate volumes for VMs
    vm_volumes =
      Enum.map(masters ++ workers, fn vm ->
        %Volume{
          name: "#{vm.name}-disk",
          pool: pool.name,
          size: vm.disk_size,
          format: "qcow2",
          base_volume: base_volume.name
        }
      end)

    %{
      pool: pool,
      network: network,
      base_volume: base_volume,
      volumes: vm_volumes,
      vms: masters ++ workers,
      config: config
    }
  end

  @doc """
  Computes actions needed to achieve desired state
  """
  def compute_actions(current, desired) do
    actions = []

    # Pool actions
    actions =
      if desired.pool.name not in current.pools do
        actions ++
          [
            %Action{
              type: :create,
              resource_type: :pool,
              resource: desired.pool,
              reason: "Pool '#{desired.pool.name}' does not exist"
            }
          ]
      else
        actions
      end

    # Network actions
    actions =
      if desired.network.name not in current.networks do
        actions ++
          [
            %Action{
              type: :create,
              resource_type: :network,
              resource: desired.network,
              reason: "Network '#{desired.network.name}' does not exist"
            }
          ]
      else
        actions
      end

    # Base volume action
    base_exists =
      Enum.any?(current.volumes, fn {pool, vol} ->
        pool == desired.pool.name && vol == desired.base_volume.name
      end)

    actions =
      if not base_exists do
        actions ++
          [
            %Action{
              type: :create,
              resource_type: :volume,
              resource: desired.base_volume,
              reason: "Base volume '#{desired.base_volume.name}' does not exist"
            }
          ]
      else
        actions
      end

    # VM volumes and domains actions
    vm_actions =
      Enum.flat_map(desired.vms, fn vm ->
        volume = Enum.find(desired.volumes, &(&1.name == "#{vm.name}-disk"))
        
        volume_exists =
          Enum.any?(current.volumes, fn {pool, vol} ->
            pool == desired.pool.name && vol == volume.name
          end)

        domain_exists = vm.name in current.domains

        volume_action =
          if not volume_exists do
            [
              %Action{
                type: :create,
                resource_type: :volume,
                resource: volume,
                reason: "Volume '#{volume.name}' does not exist"
              }
            ]
          else
            []
          end

        cloudinit_action =
          if not domain_exists do
            [
              %Action{
                type: :create,
                resource_type: :cloudinit,
                resource: %{vm: vm, config: desired.config},
                reason: "Cloud-init for '#{vm.name}' needs to be generated"
              }
            ]
          else
            []
          end

        domain_action =
          if not domain_exists do
            [
              %Action{
                type: :create,
                resource_type: :domain,
                resource: vm,
                reason: "Domain '#{vm.name}' does not exist"
              }
            ]
          else
            []
          end

        volume_action ++ cloudinit_action ++ domain_action
      end)

    actions ++ vm_actions
  end

  @doc """
  Displays a plan in human-readable format
  """
  def display_plan(actions) do
    if Enum.empty?(actions) do
      IO.puts("\n✅ Infrastructure is up to date. No changes needed.\n")
    else
      IO.puts("\n📋 Planned Changes:")
      IO.puts("=" |> String.duplicate(60))

      grouped = Enum.group_by(actions, & &1.type)

      if creates = grouped[:create] do
        IO.puts("\n🆕 Resources to create:")
        Enum.each(creates, &display_action/1)
      end

      if updates = grouped[:update] do
        IO.puts("\n♻️  Resources to update:")
        Enum.each(updates, &display_action/1)
      end

      if destroys = grouped[:destroy] do
        IO.puts("\n🗑️  Resources to destroy:")
        Enum.each(destroys, &display_action/1)
      end

      IO.puts("\n" <> "=" |> String.duplicate(60))
      IO.puts("Total: #{length(actions)} change(s)\n")
    end
  end

  defp display_action(%Action{} = action) do
    icon = case action.resource_type do
      :pool -> "💾"
      :network -> "🌐"
      :volume -> "📦"
      :domain -> "🖥️"
      :cloudinit -> "☁️"
      _ -> "•"
    end

    name = case action.resource do
      %{name: name} -> name
      %{vm: %{name: name}} -> "#{name}-cloudinit"
      _ -> "unknown"
    end

    IO.puts("  #{icon} #{action.resource_type}: #{name}")
    IO.puts("     └─ #{action.reason}")
  end

  defp get_adapter do
    Application.get_env(:romulus_elixir, :libvirt_adapter, Romulus.Libvirt.Virsh)
  end
end