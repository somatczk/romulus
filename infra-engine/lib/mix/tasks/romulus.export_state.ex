defmodule Mix.Tasks.Romulus.ExportState do
  @moduledoc """
  Export current infrastructure state to various formats.
  
  This Mix task exports the current state of the Romulus infrastructure
  including networks, storage pools, volumes, and domains to JSON or YAML format.
  
  ## Usage
  
      mix romulus.export_state [options]
  
  ## Options
  
    * `--output` (`-o`) - Output file path (optional, defaults to stdout)
    * `--format` (`-f`) - Output format: "json" or "yaml" (default: "json")
  
  ## Examples
  
      # Export to stdout in JSON format
      mix romulus.export_state
      
      # Export to file in YAML format
      mix romulus.export_state --output state.yaml --format yaml
      
      # Export to JSON file
      mix romulus.export_state -o infrastructure.json
  
  ## Exit Codes
  
    * 0 - Success
    * 1 - Error occurred during export
  """
  
  use Mix.Task
  
  alias Romulus.Core.State
  
  @shortdoc "Export current infrastructure state"
  
  @typedoc "Supported export formats"
  @type format :: :json | :yaml
  
  @typedoc "Command line options"
  @type options :: %{
    output: String.t() | nil,
    format: format()
  }
  
  @typedoc "Infrastructure state export structure"
  @type export_data :: %{
    timestamp: String.t(),
    version: String.t(),
    backend: String.t(),
    infrastructure: %{
      networks: list(map()),
      pools: list(map()),
      volumes: list(map()),
      domains: list(map())
    },
    statistics: %{
      total_networks: non_neg_integer(),
      total_pools: non_neg_integer(),
      total_volumes: non_neg_integer(),
      total_domains: non_neg_integer(),
      active_domains: non_neg_integer()
    }
  }
  
  @doc """
  Main entry point for the export state Mix task.
  
  Parses command line arguments and orchestrates the state export process.
  
  ## Parameters
  
    * `args` - List of command line arguments
  
  ## Returns
  
  This function does not return a value. It either completes successfully
  or exits with status code 1 on error.
  """
  @spec run([String.t()]) :: :ok | no_return()
  def run(args) do
    with :ok <- ensure_application_started(),
         {:ok, options} <- parse_arguments(args),
         {:ok, content} <- export_state(options.format),
         :ok <- write_output(content, options.output) do
      :ok
    else
      {:error, reason} ->
        Mix.shell().error("Export failed: #{reason}")
        exit({:shutdown, 1})
    end
  end
  
  @doc false
  @spec ensure_application_started() :: :ok | {:error, String.t()}
  defp ensure_application_started do
    case Application.ensure_all_started(:romulus_elixir) do
      {:ok, _apps} -> :ok
      {:error, reason} -> {:error, "Failed to start application: #{inspect(reason)}"}
    end
  end
  
  @doc false
  @spec parse_arguments([String.t()]) :: {:ok, options()} | {:error, String.t()}
  defp parse_arguments(args) do
    case OptionParser.parse(args,
           switches: [output: :string, format: :string],
           aliases: [o: :output, f: :format]) do
      {opts, [], []} ->
        format_str = Keyword.get(opts, :format, "json")
        output = Keyword.get(opts, :output)
        
        case validate_format(format_str) do
          {:ok, format} ->
            {:ok, %{format: format, output: output}}
          {:error, _} = error ->
            error
        end
        
      {_, [], invalid} ->
        {:error, "Invalid options: #{Enum.join(Keyword.keys(invalid), ", ")}"}
        
      {_, unexpected, _} ->
        {:error, "Unexpected arguments: #{Enum.join(unexpected, ", ")}"}
    end
  end
  
  @doc false
  @spec validate_format(String.t()) :: {:ok, format()} | {:error, String.t()}
  defp validate_format("json"), do: {:ok, :json}
  defp validate_format("yaml"), do: {:ok, :yaml}
  defp validate_format(format), do: {:error, "Unsupported format '#{format}'. Use 'json' or 'yaml'."}
  
  @doc false
  @spec write_output(String.t(), String.t() | nil) :: :ok | {:error, String.t()}
  defp write_output(content, nil) do
    IO.puts(content)
    :ok
  end
  
  defp write_output(content, output_path) do
    case File.write(output_path, content) do
      :ok ->
        Mix.shell().info("State exported to #{output_path}")
        :ok
      {:error, reason} ->
        {:error, "Failed to write to #{output_path}: #{:file.format_error(reason)}"}
    end
  end
  
  @doc false
  @spec export_state(format()) :: {:ok, String.t()} | {:error, String.t()}
  defp export_state(format) do
    with {:ok, state} <- Romulus.Core.State.fetch_current(),
         {:ok, export_data} <- build_export_data(state),
         {:ok, content} <- format_export(export_data, format) do
      {:ok, content}
    else
      {:error, reason} -> {:error, "State export failed: #{reason}"}
    end
  end
  
  @doc false
  @spec build_export_data(map()) :: {:ok, export_data()} | {:error, String.t()}
  defp build_export_data(state) do
    try do
      export = %{
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        version: "1.0.0",
        backend: "elixir",
        infrastructure: %{
          networks: serialize_networks(state.networks || []),
          pools: serialize_pools(state.pools || []),
          volumes: serialize_volumes(state.volumes || []),
          domains: serialize_domains(state.domains || [])
        },
        statistics: calculate_statistics(state)
      }
      
      {:ok, export}
    rescue
      error -> {:error, "Failed to build export data: #{Exception.message(error)}"}
    end
  end
  
  @doc false
  @spec calculate_statistics(map()) :: map()
  defp calculate_statistics(state) do
    networks = state.networks || []
    pools = state.pools || []
    volumes = state.volumes || []
    domains = state.domains || []
    
    %{
      total_networks: length(networks),
      total_pools: length(pools),
      total_volumes: length(volumes),
      total_domains: length(domains),
      active_domains: Enum.count(domains, &(&1.state == :running))
    }
  end
  
  @doc false
  @spec format_export(export_data(), format()) :: {:ok, String.t()} | {:error, String.t()}
  defp format_export(export_data, :json) do
    case Jason.encode(export_data, pretty: true) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, "JSON encoding failed: #{inspect(reason)}"}
    end
  end
  
  defp format_export(export_data, :yaml) do
    {:ok, yaml_encode(export_data)}
  end
  
  @doc false
  @spec serialize_networks(list()) :: list(map())
  defp serialize_networks(networks) when is_list(networks) do
    Enum.map(networks, &serialize_network/1)
  end
  
  defp serialize_networks(_), do: []
  
  @doc false
  @spec serialize_network(map()) :: map()
  defp serialize_network(network) do
    %{
      name: Map.get(network, :name, "unknown"),
      mode: Map.get(network, :mode, "unknown"),
      domain: Map.get(network, :domain),
      addresses: Map.get(network, :addresses, []),
      dhcp: Map.get(network, :dhcp, false),
      dns: Map.get(network, :dns, []),
      active: Map.get(network, :active, false)
    }
  end
  
  @doc false
  @spec serialize_pools(list()) :: list(map())
  defp serialize_pools(pools) when is_list(pools) do
    Enum.map(pools, &serialize_pool/1)
  end
  
  defp serialize_pools(_), do: []
  
  @doc false
  @spec serialize_pool(map()) :: map()
  defp serialize_pool(pool) do
    %{
      name: Map.get(pool, :name, "unknown"),
      type: Map.get(pool, :type, "unknown"),
      path: Map.get(pool, :path),
      active: Map.get(pool, :active, false),
      capacity: Map.get(pool, :capacity),
      allocation: Map.get(pool, :allocation),
      available: Map.get(pool, :available)
    }
  end
  
  @doc false
  @spec serialize_volumes(list()) :: list(map())
  defp serialize_volumes(volumes) when is_list(volumes) do
    Enum.map(volumes, &serialize_volume/1)
  end
  
  defp serialize_volumes(_), do: []
  
  @doc false
  @spec serialize_volume(map()) :: map()
  defp serialize_volume(volume) do
    %{
      name: Map.get(volume, :name, "unknown"),
      pool: Map.get(volume, :pool),
      size: Map.get(volume, :size),
      format: Map.get(volume, :format, "unknown"),
      path: Map.get(volume, :path),
      allocation: Map.get(volume, :allocation),
      capacity: Map.get(volume, :capacity)
    }
  end
  
  @doc false
  @spec serialize_domains(list()) :: list(map())
  defp serialize_domains(domains) when is_list(domains) do
    Enum.map(domains, &serialize_domain/1)
  end
  
  defp serialize_domains(_), do: []
  
  @doc false
  @spec serialize_domain(map()) :: map()
  defp serialize_domain(domain) do
    %{
      name: Map.get(domain, :name, "unknown"),
      memory: Map.get(domain, :memory),
      vcpu: Map.get(domain, :vcpu),
      state: Map.get(domain, :state, :unknown),
      ip_address: Map.get(domain, :ip_address),
      mac_address: Map.get(domain, :mac_address),
      os_type: Map.get(domain, :os_type),
      autostart: Map.get(domain, :autostart, false),
      persistent: Map.get(domain, :persistent, true)
    }
  end
  
  @doc false
  @spec yaml_encode(export_data()) :: String.t()
  defp yaml_encode(data) do
    # Enhanced YAML encoding with more comprehensive data
    """
    # Romulus Infrastructure State Export (YAML Summary)
    # Generated at: #{data.timestamp}
    # For complete details, use --format json
    
    version: "#{data.version}"
    backend: "#{data.backend}"
    timestamp: "#{data.timestamp}"
    
    statistics:
      total_networks: #{data.statistics.total_networks}
      total_pools: #{data.statistics.total_pools}
      total_volumes: #{data.statistics.total_volumes}
      total_domains: #{data.statistics.total_domains}
      active_domains: #{data.statistics.active_domains}
    
    infrastructure:
      networks:
    #{yaml_encode_networks(data.infrastructure.networks)}
      
      pools:
    #{yaml_encode_pools(data.infrastructure.pools)}
      
      volumes:
    #{yaml_encode_volumes(data.infrastructure.volumes)}
      
      domains:
    #{yaml_encode_domains(data.infrastructure.domains)}
    """
  end
  
  @doc false
  @spec yaml_encode_networks(list()) :: String.t()
  defp yaml_encode_networks([]), do: "        # No networks found"
  defp yaml_encode_networks(networks) do
    networks
    |> Enum.take(5)  # Limit to first 5 for summary
    |> Enum.with_index()
    |> Enum.map(fn {network, _index} ->
      "        - name: \"#{network.name}\"\n          mode: \"#{network.mode}\"\n          active: #{network.active}"
    end)
    |> Enum.join("\n")
    |> then(fn result ->
      if length(networks) > 5 do
        result <> "\n        # ... and #{length(networks) - 5} more networks"
      else
        result
      end
    end)
  end
  
  @doc false
  @spec yaml_encode_pools(list()) :: String.t()
  defp yaml_encode_pools([]), do: "        # No storage pools found"
  defp yaml_encode_pools(pools) do
    pools
    |> Enum.take(5)
    |> Enum.map(fn pool ->
      "        - name: \"#{pool.name}\"\n          type: \"#{pool.type}\"\n          active: #{pool.active}"
    end)
    |> Enum.join("\n")
    |> then(fn result ->
      if length(pools) > 5 do
        result <> "\n        # ... and #{length(pools) - 5} more pools"
      else
        result
      end
    end)
  end
  
  @doc false
  @spec yaml_encode_volumes(list()) :: String.t()
  defp yaml_encode_volumes([]), do: "        # No volumes found"
  defp yaml_encode_volumes(volumes) do
    volumes
    |> Enum.take(5)
    |> Enum.map(fn volume ->
      "        - name: \"#{volume.name}\"\n          format: \"#{volume.format}\"\n          size: #{volume.size || "unknown"}"
    end)
    |> Enum.join("\n")
    |> then(fn result ->
      if length(volumes) > 5 do
        result <> "\n        # ... and #{length(volumes) - 5} more volumes"
      else
        result
      end
    end)
  end
  
  @doc false
  @spec yaml_encode_domains(list()) :: String.t()
  defp yaml_encode_domains([]), do: "        # No domains found"
  defp yaml_encode_domains(domains) do
    domains
    |> Enum.take(10)  # Show more domains as they're often the most important
    |> Enum.map(fn domain ->
      ip_info = if domain.ip_address, do: " (#{domain.ip_address})", else: ""
      "        - name: \"#{domain.name}\"#{ip_info}\n          state: #{domain.state}\n          memory: #{domain.memory || "unknown"}\n          vcpu: #{domain.vcpu || "unknown"}"
    end)
    |> Enum.join("\n")
    |> then(fn result ->
      if length(domains) > 10 do
        result <> "\n        # ... and #{length(domains) - 10} more domains"
      else
        result
      end
    end)
  end
end