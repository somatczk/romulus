defmodule Romulus.Libvirt.Adapter do
  @moduledoc """
  Behaviour for libvirt interactions.
  Provides abstraction over different libvirt interaction methods.
  """

  alias Romulus.State.Schema.{VM, Network, Pool, Volume}

  @type error :: {:error, String.t()}

  @callback list_domains() :: {:ok, [String.t()]} | error()
  @callback get_domain(String.t()) :: {:ok, map()} | error()
  @callback create_domain(VM.t(), String.t()) :: :ok | error()
  @callback destroy_domain(String.t()) :: :ok | error()
  @callback delete_domain(String.t()) :: :ok | error()

  @callback list_networks() :: {:ok, [String.t()]} | error()
  @callback get_network(String.t()) :: {:ok, map()} | error()
  @callback create_network(Network.t()) :: :ok | error()
  @callback destroy_network(String.t()) :: :ok | error()

  @callback list_pools() :: {:ok, [String.t()]} | error()
  @callback get_pool(String.t()) :: {:ok, map()} | error()
  @callback create_pool(Pool.t()) :: :ok | error()
  @callback destroy_pool(String.t()) :: :ok | error()

  @callback list_volumes(String.t()) :: {:ok, [String.t()]} | error()
  @callback get_volume(String.t(), String.t()) :: {:ok, map()} | error()
  @callback create_volume(Volume.t()) :: :ok | error()
  @callback delete_volume(String.t(), String.t()) :: :ok | error()

  @callback create_cloudinit_iso(String.t(), String.t(), String.t(), String.t()) ::
              {:ok, String.t()} | error()
end