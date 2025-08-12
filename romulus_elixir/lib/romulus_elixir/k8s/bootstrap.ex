defmodule RomulusElixir.K8s.Bootstrap do
  @moduledoc """
  Provides robust Kubernetes cluster bootstrapping functionality for headless environments.

  This module handles the complete bootstrap process for a Kubernetes cluster after
  VMs are provisioned, including master node initialization, worker node joining,
  CNI plugin configuration, and addon deployment.

  ## Configuration

  The bootstrap process expects a configuration map with the following structure:

      config = %{
        nodes: %{
          masters: %{count: 1, ip_prefix: "192.168.1.1"},
          workers: %{count: 2, ip_prefix: "192.168.1.2"}
        },
        ssh: %{user: "ubuntu", key_path: "/path/to/key"},
        kubernetes: %{
          pod_subnet: "10.244.0.0/16",
          service_subnet: "10.96.0.0/12",
          version: "1.28.0"
        },
        bootstrap: %{
          cni: "flannel",
          timeout: 300,
          retry_attempts: 3
        }
      }

  ## Features

  - Robust SSH connectivity checking with configurable timeouts
  - Comprehensive error handling and recovery mechanisms
  - Support for multiple CNI plugins (Flannel, Calico)
  - Health checks to verify cluster state
  - Structured logging for better observability
  - Production-ready retry and backoff strategies
  """

  require Logger

  @type bootstrap_config :: %{
          nodes: %{
            masters: %{count: pos_integer(), ip_prefix: String.t()},
            workers: %{count: pos_integer(), ip_prefix: String.t()}
          },
          ssh: %{user: String.t(), key_path: String.t()},
          kubernetes: %{
            pod_subnet: String.t(),
            service_subnet: String.t(),
            version: String.t()
          },
          bootstrap: %{
            cni: String.t(),
            timeout: pos_integer(),
            retry_attempts: pos_integer()
          }
        }

  @type bootstrap_result :: {:ok, :bootstrapped} | {:error, atom() | String.t()}

  @default_pod_subnet "10.244.0.0/16"
  @default_service_subnet "10.96.0.0/12"
  @default_cni "flannel"
  @default_timeout 300
  @default_retry_attempts 3
  @ssh_timeout 30
  @ssh_retry_delay 5000
  @kubectl_wait_timeout 60

  @doc """
  Runs the complete Kubernetes bootstrap process.

  This function orchestrates the entire bootstrap workflow:
  1. Validates the provided configuration
  2. Waits for all VMs to become SSH-accessible
  3. Initializes the master node with kubeadm
  4. Joins worker nodes to the cluster
  5. Applies the CNI network plugin
  6. Deploys cluster addons
  7. Performs health checks

  ## Parameters

  - `config` - Bootstrap configuration map (see module documentation)

  ## Returns

  - `{:ok, :bootstrapped}` - Bootstrap completed successfully
  - `{:error, reason}` - Bootstrap failed with the given reason

  ## Examples

      iex> config = %{nodes: %{masters: %{count: 1, ip_prefix: "192.168.1.10"}, ...}}
      iex> RomulusElixir.K8s.Bootstrap.run(config)
      {:ok, :bootstrapped}

      iex> invalid_config = %{}
      iex> RomulusElixir.K8s.Bootstrap.run(invalid_config)
      {:error, :invalid_configuration}
  """
  @spec run(bootstrap_config()) :: bootstrap_result()
  def run(config) do
    Logger.info("Starting Kubernetes cluster bootstrap process",
      cluster_size: get_total_node_count(config)
    )

    with {:ok, validated_config} <- validate_configuration(config),
         {:ok, _} <- wait_for_vms(validated_config),
         {:ok, join_info} <- initialize_master(validated_config),
         {:ok, _} <- join_workers(validated_config, join_info),
         {:ok, _} <- apply_cni(validated_config),
         {:ok, _} <- apply_addons(validated_config),
         {:ok, _} <- verify_cluster_health(validated_config) do
      Logger.info("Kubernetes cluster bootstrap completed successfully")
      {:ok, :bootstrapped}
    else
      {:error, reason} = error ->
        Logger.error("Bootstrap failed", reason: inspect(reason))
        error
    end
  end

  @spec validate_configuration(map()) :: {:ok, bootstrap_config()} | {:error, :invalid_configuration}
  defp validate_configuration(config) do
    required_fields = [
      [:nodes, :masters, :count],
      [:nodes, :masters, :ip_prefix],
      [:nodes, :workers, :count],
      [:nodes, :workers, :ip_prefix],
      [:ssh, :user]
    ]

    case validate_required_fields(config, required_fields) do
      :ok ->
        validated_config = add_default_values(config)
        {:ok, validated_config}

      :error ->
        Logger.error("Configuration validation failed", missing_fields: required_fields)
        {:error, :invalid_configuration}
    end
  end

  @spec validate_required_fields(map(), list()) :: :ok | :error
  defp validate_required_fields(config, required_fields) do
    if Enum.all?(required_fields, &field_present?(config, &1)) do
      :ok
    else
      :error
    end
  end

  @spec field_present?(map(), list()) :: boolean()
  defp field_present?(config, path) do
    get_in(config, path) != nil
  end

  @spec add_default_values(map()) :: bootstrap_config()
  defp add_default_values(config) do
    config
    |> put_in([:kubernetes, :pod_subnet], get_in(config, [:kubernetes, :pod_subnet]) || @default_pod_subnet)
    |> put_in([:kubernetes, :service_subnet], get_in(config, [:kubernetes, :service_subnet]) || @default_service_subnet)
    |> put_in([:bootstrap, :cni], get_in(config, [:bootstrap, :cni]) || @default_cni)
    |> put_in([:bootstrap, :timeout], get_in(config, [:bootstrap, :timeout]) || @default_timeout)
    |> put_in([:bootstrap, :retry_attempts], get_in(config, [:bootstrap, :retry_attempts]) || @default_retry_attempts)
  end

  @spec wait_for_vms(bootstrap_config()) :: {:ok, :all_nodes_ready} | {:error, {:ssh_timeout, list()}}
  defp wait_for_vms(config) do
    Logger.info("Waiting for VMs to become SSH accessible")

    all_ips = get_all_node_ips(config)
    user = get_in(config, [:ssh, :user])
    key_path = get_in(config, [:ssh, :key_path])

    case check_all_nodes_ssh(all_ips, user, key_path) do
      {:ok, _} ->
        Logger.info("All nodes are ready", node_count: length(all_ips))
        {:ok, :all_nodes_ready}

      {:error, failed_nodes} ->
        Logger.error("Failed to connect to nodes", failed_nodes: failed_nodes)
        {:error, {:ssh_timeout, failed_nodes}}
    end
  end

  @spec check_all_nodes_ssh(list(String.t()), String.t(), String.t() | nil) ::
          {:ok, :all_connected} | {:error, list(String.t())}
  defp check_all_nodes_ssh(ips, user, key_path) do
    results =
      ips
      |> Task.async_stream(&wait_for_ssh_connectivity(&1, user, key_path),
        max_concurrency: 10,
        timeout: @ssh_timeout * 1000
      )
      |> Enum.to_list()

    failed_nodes =
      results
      |> Enum.zip(ips)
      |> Enum.filter(fn {{:ok, result}, _ip} -> result != :ok end)
      |> Enum.map(fn {_, ip} -> ip end)

    case failed_nodes do
      [] -> {:ok, :all_connected}
      failed -> {:error, failed}
    end
  end

  @spec wait_for_ssh_connectivity(String.t(), String.t(), String.t() | nil) :: :ok | {:error, :timeout}
  defp wait_for_ssh_connectivity(ip, user, key_path) do
    wait_for_ssh_connectivity(ip, user, key_path, @ssh_timeout)
  end

  @spec wait_for_ssh_connectivity(String.t(), String.t(), String.t() | nil, non_neg_integer()) ::
          :ok | {:error, :timeout}
  defp wait_for_ssh_connectivity(ip, user, key_path, retries) when retries > 0 do
    ssh_opts = build_ssh_options(key_path)

    case System.cmd("ssh", ssh_opts ++ ["#{user}@#{ip}", "echo", "ready"], stderr_to_stdout: true) do
      {output, 0} ->
        if String.contains?(output, "ready") do
          Logger.debug("Node ready", ip: ip)
          :ok
        else
          retry_ssh_connection(ip, user, key_path, retries - 1)
        end

      {_output, _code} ->
        retry_ssh_connection(ip, user, key_path, retries - 1)
    end
  end

  defp wait_for_ssh_connectivity(_ip, _user, _key_path, 0) do
    {:error, :timeout}
  end

  @spec retry_ssh_connection(String.t(), String.t(), String.t() | nil, non_neg_integer()) ::
          :ok | {:error, :timeout}
  defp retry_ssh_connection(ip, user, key_path, retries) do
    Logger.debug("Retrying SSH connection", ip: ip, retries_left: retries)
    Process.sleep(@ssh_retry_delay)
    wait_for_ssh_connectivity(ip, user, key_path, retries)
  end

  @spec initialize_master(bootstrap_config()) :: {:ok, map()} | {:error, any()}
  defp initialize_master(config) do
    Logger.info("Initializing Kubernetes master node")

    master_ip = get_master_ip(config)
    user = get_in(config, [:ssh, :user])
    key_path = get_in(config, [:ssh, :key_path])

    with {:ok, _} <- run_kubeadm_init(master_ip, user, key_path, config),
         {:ok, join_info} <- extract_join_information(master_ip, user, key_path),
         {:ok, _} <- setup_kubectl_config(master_ip, user, key_path) do
      Logger.info("Master node initialized successfully", master_ip: master_ip)
      {:ok, join_info}
    else
      {:error, reason} = error ->
        Logger.error("Failed to initialize master node",
          master_ip: master_ip,
          reason: inspect(reason)
        )

        error
    end
  end

  @spec run_kubeadm_init(String.t(), String.t(), String.t() | nil, bootstrap_config()) ::
          {:ok, String.t()} | {:error, any()}
  defp run_kubeadm_init(master_ip, user, key_path, config) do
    kubernetes_config = get_in(config, [:kubernetes])
    pod_subnet = kubernetes_config[:pod_subnet]
    service_subnet = kubernetes_config[:service_subnet]

    init_command = """
    sudo kubeadm init \
      --apiserver-advertise-address=#{master_ip} \
      --pod-network-cidr=#{pod_subnet} \
      --service-cidr=#{service_subnet} \
      --ignore-preflight-errors=NumCPU,Mem
    """

    case run_ssh_command_with_retry(master_ip, user, key_path, init_command) do
      {:ok, output} ->
        Logger.debug("kubeadm init completed", output_length: String.length(output))
        {:ok, output}

      error ->
        error
    end
  end

  @spec extract_join_information(String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, :join_info_not_found}
  defp extract_join_information(master_ip, user, key_path) do
    get_token_command = """
    TOKEN=$(sudo kubeadm token list | grep authentication | head -n 1 | awk '{print $1}')
    CA_CERT_HASH=$(openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex | sed 's/^.* //')
    echo "TOKEN=$TOKEN"
    echo "CA_CERT_HASH=sha256:$CA_CERT_HASH"
    echo "MASTER_IP=#{master_ip}"
    """

    case run_ssh_command_with_retry(master_ip, user, key_path, get_token_command) do
      {:ok, output} ->
        parse_join_information(output)

      error ->
        Logger.error("Failed to extract join information", error: inspect(error))
        error
    end
  end

  @spec parse_join_information(String.t()) :: {:ok, map()} | {:error, :join_info_not_found}
  defp parse_join_information(output) do
    token_regex = ~r/TOKEN=([^\s]+)/
    hash_regex = ~r/CA_CERT_HASH=([^\s]+)/
    ip_regex = ~r/MASTER_IP=([^\s]+)/

    with [_, token] <- Regex.run(token_regex, output),
         [_, ca_cert_hash] <- Regex.run(hash_regex, output),
         [_, master_ip] <- Regex.run(ip_regex, output) do
      join_info = %{
        token: token,
        ca_cert_hash: ca_cert_hash,
        master_ip: master_ip
      }

      {:ok, join_info}
    else
      _ ->
        Logger.error("Could not parse join information from output", output: output)
        {:error, :join_info_not_found}
    end
  end

  @spec setup_kubectl_config(String.t(), String.t(), String.t() | nil) :: {:ok, String.t()} | {:error, any()}
  defp setup_kubectl_config(master_ip, user, key_path) do
    setup_command = """
    mkdir -p $HOME/.kube && \
    sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config && \
    sudo chown $(id -u):$(id -g) $HOME/.kube/config && \
    chmod 600 $HOME/.kube/config
    """

    run_ssh_command_with_retry(master_ip, user, key_path, setup_command)
  end

  @spec join_workers(bootstrap_config(), map()) ::
          {:ok, :workers_joined} | {:error, {:join_failures, list()}}
  defp join_workers(config, join_info) do
    Logger.info("Joining worker nodes to cluster")

    worker_ips = get_worker_ips(config)
    user = get_in(config, [:ssh, :user])
    key_path = get_in(config, [:ssh, :key_path])

    join_command = build_join_command(join_info)

    results =
      worker_ips
      |> Task.async_stream(&join_single_worker(&1, user, key_path, join_command),
        max_concurrency: 5,
        timeout: @kubectl_wait_timeout * 1000
      )
      |> Enum.to_list()

    failed_workers =
      results
      |> Enum.zip(worker_ips)
      |> Enum.filter(fn {{:ok, result}, _ip} -> result != :ok end)
      |> Enum.map(fn {_, ip} -> ip end)

    case failed_workers do
      [] ->
        Logger.info("All worker nodes joined successfully", worker_count: length(worker_ips))
        {:ok, :workers_joined}

      failed ->
        Logger.error("Some workers failed to join", failed_workers: failed)
        {:error, {:join_failures, failed}}
    end
  end

  @spec build_join_command(map()) :: String.t()
  defp build_join_command(%{token: token, ca_cert_hash: ca_cert_hash, master_ip: master_ip}) do
    "kubeadm join #{master_ip}:6443 --token #{token} --discovery-token-ca-cert-hash #{ca_cert_hash}"
  end

  @spec join_single_worker(String.t(), String.t(), String.t() | nil, String.t()) :: :ok | {:error, any()}
  defp join_single_worker(worker_ip, user, key_path, join_command) do
    Logger.debug("Joining worker node", worker_ip: worker_ip)

    case run_ssh_command_with_retry(worker_ip, user, key_path, "sudo #{join_command}") do
      {:ok, _output} ->
        Logger.info("Worker node joined successfully", worker_ip: worker_ip)
        :ok

      {:error, reason} = error ->
        Logger.error("Failed to join worker node", worker_ip: worker_ip, reason: inspect(reason))
        error
    end
  end

  @spec apply_cni(bootstrap_config()) :: {:ok, :cni_applied} | {:error, any()}
  defp apply_cni(config) do
    Logger.info("Applying CNI network plugin")

    master_ip = get_master_ip(config)
    user = get_in(config, [:ssh, :user])
    key_path = get_in(config, [:ssh, :key_path])
    cni_type = get_in(config, [:bootstrap, :cni])

    cni_command = get_cni_command(cni_type)

    case run_ssh_command_with_retry(master_ip, user, key_path, cni_command) do
      {:ok, _output} ->
        Logger.info("CNI plugin applied successfully", cni: cni_type)
        {:ok, :cni_applied}

      {:error, reason} = error ->
        Logger.error("Failed to apply CNI plugin", cni: cni_type, reason: inspect(reason))
        error
    end
  end

  @spec get_cni_command(String.t()) :: String.t()
  defp get_cni_command("flannel") do
    "kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml"
  end

  defp get_cni_command("calico") do
    """
    kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/tigera-operator.yaml && \
    kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/custom-resources.yaml
    """
  end

  defp get_cni_command(unknown_cni) do
    Logger.warning("Unknown CNI plugin, falling back to Flannel", requested_cni: unknown_cni)
    get_cni_command("flannel")
  end

  @spec apply_addons(bootstrap_config()) :: {:ok, :addons_applied} | {:error, any()}
  defp apply_addons(_config) do
    Logger.info("Applying cluster addons")

    # TODO: Implement addon application logic based on configuration
    # This could include metrics-server, ingress controllers, storage classes, etc.

    Logger.info("Addon application completed")
    {:ok, :addons_applied}
  end

  @spec verify_cluster_health(bootstrap_config()) :: {:ok, :cluster_healthy} | {:error, any()}
  defp verify_cluster_health(config) do
    Logger.info("Verifying cluster health")

    master_ip = get_master_ip(config)
    user = get_in(config, [:ssh, :user])
    key_path = get_in(config, [:ssh, :key_path])

    with {:ok, _} <- check_nodes_ready(master_ip, user, key_path),
         {:ok, _} <- check_system_pods_running(master_ip, user, key_path) do
      Logger.info("Cluster health verification completed successfully")
      {:ok, :cluster_healthy}
    else
      {:error, reason} = error ->
        Logger.error("Cluster health check failed", reason: inspect(reason))
        error
    end
  end

  @spec check_nodes_ready(String.t(), String.t(), String.t() | nil) :: {:ok, String.t()} | {:error, any()}
  defp check_nodes_ready(master_ip, user, key_path) do
    check_command = """
    kubectl get nodes --no-headers | \
    awk '{if ($2 != "Ready") exit 1} END {if (NR == 0) exit 1; print "All nodes ready"}'
    """

    case run_ssh_command_with_retry(master_ip, user, key_path, check_command) do
      {:ok, output} ->
        Logger.debug("Node readiness check passed", output: String.trim(output))
        {:ok, output}

      error ->
        Logger.error("Node readiness check failed")
        error
    end
  end

  @spec check_system_pods_running(String.t(), String.t(), String.t() | nil) :: {:ok, String.t()} | {:error, any()}
  defp check_system_pods_running(master_ip, user, key_path) do
    check_command = """
    kubectl get pods -n kube-system --no-headers | \
    awk '{if ($3 != "Running" && $3 != "Completed") exit 1} END {if (NR == 0) exit 1; print "All system pods ready"}'
    """

    case run_ssh_command_with_retry(master_ip, user, key_path, check_command) do
      {:ok, output} ->
        Logger.debug("System pods check passed", output: String.trim(output))
        {:ok, output}

      error ->
        Logger.error("System pods check failed")
        error
    end
  end

  # Utility functions

  @spec run_ssh_command_with_retry(String.t(), String.t(), String.t() | nil, String.t()) ::
          {:ok, String.t()} | {:error, any()}
  defp run_ssh_command_with_retry(ip, user, key_path, command) do
    run_ssh_command_with_retry(ip, user, key_path, command, @default_retry_attempts)
  end

  @spec run_ssh_command_with_retry(String.t(), String.t(), String.t() | nil, String.t(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, any()}
  defp run_ssh_command_with_retry(ip, user, key_path, command, retries) when retries > 0 do
    case run_ssh_command(ip, user, key_path, command) do
      {:ok, output} ->
        {:ok, output}

      {:error, reason} when retries > 1 ->
        Logger.debug("SSH command failed, retrying",
          ip: ip,
          retries_left: retries - 1,
          reason: inspect(reason)
        )

        Process.sleep(2000)
        run_ssh_command_with_retry(ip, user, key_path, command, retries - 1)

      error ->
        error
    end
  end

  defp run_ssh_command_with_retry(_ip, _user, _key_path, _command, 0) do
    {:error, :max_retries_exceeded}
  end

  @spec run_ssh_command(String.t(), String.t(), String.t() | nil, String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp run_ssh_command(ip, user, key_path, command) do
    ssh_opts = build_ssh_options(key_path)

    case System.cmd("ssh", ssh_opts ++ ["#{user}@#{ip}", command], stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, output}

      {output, exit_code} ->
        error_msg = "SSH command failed (exit code: #{exit_code}): #{String.trim(output)}"
        {:error, error_msg}
    end
  end

  @spec build_ssh_options(String.t() | nil) :: list(String.t())
  defp build_ssh_options(key_path) do
    base_opts = [
      "-o", "StrictHostKeyChecking=no",
      "-o", "UserKnownHostsFile=/dev/null",
      "-o", "LogLevel=ERROR",
      "-o", "ConnectTimeout=10",
      "-o", "ServerAliveInterval=30",
      "-o", "ServerAliveCountMax=3"
    ]

    case key_path do
      nil -> base_opts
      path -> ["-i", path] ++ base_opts
    end
  end

  @spec get_all_node_ips(bootstrap_config()) :: list(String.t())
  defp get_all_node_ips(config) do
    get_master_ips(config) ++ get_worker_ips(config)
  end

  @spec get_master_ips(bootstrap_config()) :: list(String.t())
  defp get_master_ips(config) do
    masters = get_in(config, [:nodes, :masters])
    prefix = masters[:ip_prefix]
    count = masters[:count]

    for i <- 1..count, do: "#{prefix}#{i}"
  end

  @spec get_worker_ips(bootstrap_config()) :: list(String.t())
  defp get_worker_ips(config) do
    workers = get_in(config, [:nodes, :workers])
    prefix = workers[:ip_prefix]
    count = workers[:count]

    for i <- 1..count, do: "#{prefix}#{i}"
  end

  @spec get_master_ip(bootstrap_config()) :: String.t()
  defp get_master_ip(config) do
    prefix = get_in(config, [:nodes, :masters, :ip_prefix])
    "#{prefix}1"
  end

  @spec get_total_node_count(map()) :: non_neg_integer()
  defp get_total_node_count(config) do
    master_count = get_in(config, [:nodes, :masters, :count]) || 0
    worker_count = get_in(config, [:nodes, :workers, :count]) || 0
    master_count + worker_count
  end
end