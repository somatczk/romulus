defmodule RomulusElixir.Config do
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
  
  defp atomize_keys(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {String.to_atom(k), atomize_keys(v)} end)
    |> Enum.into([])
  end
  
  defp atomize_keys(list) when is_list(list) do
    Enum.map(list, &atomize_keys/1)
  end
  
  defp atomize_keys(value), do: value
end