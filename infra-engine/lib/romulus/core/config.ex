defmodule Romulus.Core.Config do
  @moduledoc """
  Configuration management for Romulus.
  Loads and validates configuration from YAML files.
  """
  
  alias NimbleOptions
  
  @schema [
    cluster: [
      type: :keyword_list,
      required: true,
      keys: [
        name: [type: :string, required: true],
        domain: [type: :string, required: true]
      ]
    ],
    network: [
      type: :keyword_list,
      required: true,
      keys: [
        name: [type: :string, required: true],
        mode: [type: :string, default: "nat"],
        cidr: [type: :string, required: true],
        dhcp: [type: :boolean, default: true],
        dns: [type: :boolean, default: true]
      ]
    ],
    storage: [
      type: :keyword_list,
      required: true,
      keys: [
        pool_name: [type: :string, required: true],
        pool_path: [type: :string, required: true],
        base_image: [
          type: :keyword_list,
          required: true,
          keys: [
            name: [type: :string, required: true],
            url: [type: :string, required: true],
            format: [type: :string, default: "qcow2"]
          ]
        ]
      ]
    ],
    nodes: [
      type: :keyword_list,
      required: true,
      keys: [
        masters: [
          type: :keyword_list,
          required: true,
          keys: [
            count: [type: :integer, required: true],
            memory: [type: :integer, required: true],
            vcpus: [type: :integer, required: true],
            disk_size: [type: :integer, required: true],
            ip_prefix: [type: :string, required: true]
          ]
        ],
        workers: [
          type: :keyword_list,
          required: true,
          keys: [
            count: [type: :integer, required: true],
            memory: [type: :integer, required: true],
            vcpus: [type: :integer, required: true],
            disk_size: [type: :integer, required: true],
            ip_prefix: [type: :string, required: true]
          ]
        ]
      ]
    ],
    ssh: [
      type: :keyword_list,
      required: true,
      keys: [
        public_key_path: [type: :string, required: true],
        private_key_path: [type: :string, required: false],
        user: [type: :string, default: "debian"]
      ]
    ],
    kubernetes: [
      type: :keyword_list,
      required: false,
      keys: [
        version: [type: :string, default: "1.28"],
        pod_subnet: [type: :string, default: "10.244.0.0/16"],
        service_subnet: [type: :string, default: "10.96.0.0/12"]
      ]
    ],
    bootstrap: [
      type: :keyword_list,
      required: false,
      keys: [
        cni: [type: :string, default: "flannel"],
        ingress: [type: :string, default: "nginx"],
        storage: [type: :string, default: "rook-ceph"],
        monitoring: [type: :string, default: "prometheus"],
        logging: [type: :string, default: "loki"]
      ]
    ]
  ]
  
  @doc """
  Load configuration from a YAML file.
  """
  def load(path) do
    with {:ok, content} <- File.read(path),
         {:ok, yaml} <- YamlElixir.read_from_string(content),
         config = atomize_keys(yaml),
         {:ok, validated} <- validate(config) do
      {:ok, validated}
    else
      {:error, reason} -> {:error, {:config_load_failed, reason}}
    end
  end
  
  @doc """
  Validate configuration against schema.
  """
  def validate(config) do
    NimbleOptions.validate(config, @schema)
  end
  
  @doc """
  Get the schema for configuration validation.
  """
  def schema, do: @schema
  
  @doc """
  Get default configuration file paths.
  """
  def get_default_config_paths do
    [
      "romulus.yaml",
      "romulus.yml",
      "config/romulus.yaml",
      "config/romulus.yml",
      Path.expand("~/.romulus/config.yaml"),
      Path.expand("~/.romulus/config.yml"),
      "/etc/romulus/config.yaml",
      "/etc/romulus/config.yml"
    ]
  end
  
  @doc """
  Merge two configurations with the second taking precedence.
  """
  def merge_configs(base, nil), do: base
  def merge_configs(base, override) do
    deep_merge(base, override)
  end
  
  @doc """
  Expand file paths in configuration (~ and relative paths).
  """
  def expand_paths(config) do
    config
    |> update_in([:ssh, :public_key_path], &expand_path/1)
    |> update_in_if_exists([:ssh, :private_key_path], &expand_path/1)
    |> update_in([:storage, :pool_path], &expand_path/1)
  end
  
  @doc """
  Load configuration with environment variable overrides.
  """
  def load_with_env_overrides(path) do
    with {:ok, config} <- load(path) do
      {:ok, apply_env_overrides(config)}
    end
  end
  
  defp atomize_keys(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {String.to_atom(k), atomize_keys(v)} end)
    |> Enum.into([])
  end
  
  defp atomize_keys(list) when is_list(list) do
    Enum.map(list, &atomize_keys/1)
  end
  
  defp atomize_keys(value), do: value

  # Helper functions for configuration management
  
  defp deep_merge(left, right) when is_list(left) and is_list(right) do
    case {Keyword.keyword?(left), Keyword.keyword?(right)} do
      {true, true} ->
        Keyword.merge(left, right, fn _key, left_val, right_val ->
          case {left_val, right_val} do
            {left_kw, right_kw} when is_list(left_kw) and is_list(right_kw) ->
              case {Keyword.keyword?(left_kw), Keyword.keyword?(right_kw)} do
                {true, true} -> deep_merge(left_kw, right_kw)
                _ -> right_val
              end
            _ ->
              right_val
          end
        end)
      _ ->
        right
    end
  end
  
  defp deep_merge(_left, right), do: right
  
  defp expand_path(nil), do: nil
  defp expand_path(path) when is_binary(path) do
    Path.expand(path)
  end
  
  defp update_in_if_exists(config, path, fun) do
    if get_in(config, path) do
      update_in(config, path, fun)
    else
      config
    end
  end
  
  defp apply_env_overrides(config) do
    config
    |> apply_env_override("ROMULUS_CLUSTER_NAME", [:cluster, :name])
    |> apply_env_override("ROMULUS_CLUSTER_DOMAIN", [:cluster, :domain])
    |> apply_env_override("ROMULUS_NETWORK_NAME", [:network, :name])
    |> apply_env_override("ROMULUS_NETWORK_CIDR", [:network, :cidr])
    |> apply_env_override("ROMULUS_POOL_NAME", [:storage, :pool_name])
    |> apply_env_override("ROMULUS_POOL_PATH", [:storage, :pool_path])
    |> apply_env_override("ROMULUS_SSH_PUBLIC_KEY_PATH", [:ssh, :public_key_path])
    |> apply_env_override("ROMULUS_SSH_PRIVATE_KEY_PATH", [:ssh, :private_key_path])
    |> apply_env_override("ROMULUS_SSH_USER", [:ssh, :user])
    |> apply_env_int_override("ROMULUS_MASTER_COUNT", [:nodes, :masters, :count])
    |> apply_env_int_override("ROMULUS_MASTER_MEMORY", [:nodes, :masters, :memory])
    |> apply_env_int_override("ROMULUS_MASTER_VCPUS", [:nodes, :masters, :vcpus])
    |> apply_env_int_override("ROMULUS_MASTER_DISK_SIZE", [:nodes, :masters, :disk_size])
    |> apply_env_override("ROMULUS_MASTER_IP_PREFIX", [:nodes, :masters, :ip_prefix])
    |> apply_env_int_override("ROMULUS_WORKER_COUNT", [:nodes, :workers, :count])
    |> apply_env_int_override("ROMULUS_WORKER_MEMORY", [:nodes, :workers, :memory])
    |> apply_env_int_override("ROMULUS_WORKER_VCPUS", [:nodes, :workers, :vcpus])
    |> apply_env_int_override("ROMULUS_WORKER_DISK_SIZE", [:nodes, :workers, :disk_size])
    |> apply_env_override("ROMULUS_WORKER_IP_PREFIX", [:nodes, :workers, :ip_prefix])
  end
  
  defp apply_env_override(config, env_var, path) do
    case System.get_env(env_var) do
      nil -> config
      value -> put_in(config, path, value)
    end
  end
  
  defp apply_env_int_override(config, env_var, path) do
    case System.get_env(env_var) do
      nil -> config
      value -> 
        case Integer.parse(value) do
          {int_val, ""} -> put_in(config, path, int_val)
          _ -> config
        end
    end
  end
end
