import Config

# Runtime configuration for RomulusElixir
# This configuration is loaded at runtime and can read from environment variables

# Get the runtime environment
env = config_env()

# System configuration from environment variables
default_config_paths = 
  case System.get_env("ROMULUS_CONFIG_PATHS") do
    nil -> 
      case env do
        :prod -> [
          "/etc/romulus/romulus.yaml",
          "/opt/romulus/romulus.yaml", 
          "romulus.yaml"
        ]
        :dev -> [
          "romulus.yaml",
          "config/romulus.dev.yaml"
        ]
        :test -> [
          "test/fixtures/romulus.yaml"
        ]
      end
    paths -> String.split(paths, ":")
  end

config :romulus_elixir,
  default_config_paths: default_config_paths

# Libvirt configuration from environment
if libvirt_uri = System.get_env("LIBVIRT_URI") do
  config :romulus_elixir, :libvirt, uri: libvirt_uri
end

if virsh_timeout = System.get_env("VIRSH_TIMEOUT") do
  timeout = String.to_integer(virsh_timeout)
  config :romulus_elixir, :libvirt, virsh_timeout: timeout
end

# Storage configuration from environment
if default_pool_path = System.get_env("ROMULUS_DEFAULT_POOL_PATH") do
  config :romulus_elixir, :storage, default_pool_path: default_pool_path
end

# Logging configuration from environment
log_level = 
  System.get_env("ROMULUS_LOG_LEVEL", "info")
  |> String.downcase()
  |> String.to_atom()

config :logger, level: log_level

if System.get_env("ROMULUS_STRUCTURED_LOGGING") == "true" do
  config :logger, :console,
    format: {Jason, :encode!},
    metadata: :all
end

# SSH configuration from environment
if ssh_user = System.get_env("ROMULUS_SSH_USER") do
  config :romulus_elixir, :ssh, default_user: ssh_user
end

if ssh_key_path = System.get_env("ROMULUS_SSH_KEY_PATH") do
  config :romulus_elixir, :ssh, 
    default_public_key_path: ssh_key_path <> ".pub",
    default_private_key_path: ssh_key_path
end

# Kubernetes configuration from environment
if k8s_version = System.get_env("ROMULUS_K8S_VERSION") do
  config :romulus_elixir, :kubernetes, default_version: k8s_version
end

if k8s_cni = System.get_env("ROMULUS_K8S_CNI") do
  config :romulus_elixir, :kubernetes, default_cni: k8s_cni
end

# Executor configuration from environment
if execution_mode = System.get_env("ROMULUS_EXECUTION_MODE") do
  mode = String.to_atom(execution_mode)
  config :romulus_elixir, :executor, default_mode: mode
end

if execution_timeout = System.get_env("ROMULUS_EXECUTION_TIMEOUT") do
  timeout = String.to_integer(execution_timeout)
  config :romulus_elixir, :executor, default_timeout: timeout
end

# Health check configuration from environment
if health_interval = System.get_env("ROMULUS_HEALTH_CHECK_INTERVAL") do
  interval = String.to_integer(health_interval)
  config :romulus_elixir, :health_check, check_interval: interval
end

if System.get_env("ROMULUS_AUTO_FIX") == "true" do
  config :romulus_elixir, :health_check, auto_fix: true
end

# Healing configuration from environment
if System.get_env("ROMULUS_HEALING_ENABLED") == "false" do
  config :romulus_elixir, :healing, enabled: false
end

if System.get_env("ROMULUS_AUTO_HEAL") == "true" do
  config :romulus_elixir, :healing, auto_heal: true
end

if healing_interval = System.get_env("ROMULUS_HEALING_INTERVAL") do
  interval = String.to_integer(healing_interval)
  config :romulus_elixir, :healing, check_interval: interval
end

# Security configuration from environment
if System.get_env("ROMULUS_REQUIRE_TLS") == "true" do
  config :romulus_elixir, :security, require_tls: true
end

if System.get_env("ROMULUS_AUDIT_LOGGING") == "true" do
  config :romulus_elixir, :security, audit_logging: true
end

if audit_log_path = System.get_env("ROMULUS_AUDIT_LOG_PATH") do
  config :romulus_elixir, :security, audit_log_path: audit_log_path
end

# Monitoring configuration from environment
if System.get_env("ROMULUS_METRICS_ENABLED") == "true" do
  config :romulus_elixir, :monitoring, metrics_enabled: true
  
  if metrics_port = System.get_env("ROMULUS_METRICS_PORT") do
    port = String.to_integer(metrics_port)
    config :romulus_elixir, :monitoring, metrics_port: port
  end
end

if System.get_env("ROMULUS_TELEMETRY_ENABLED") == "true" do
  config :romulus_elixir, :monitoring, telemetry_enabled: true
end

# Backup configuration from environment
if System.get_env("ROMULUS_BACKUP_ENABLED") == "true" do
  config :romulus_elixir, :backup, enabled: true
  
  if backup_dir = System.get_env("ROMULUS_BACKUP_DIR") do
    config :romulus_elixir, :backup, backup_dir: backup_dir
  end
  
  if retention_days = System.get_env("ROMULUS_BACKUP_RETENTION_DAYS") do
    days = String.to_integer(retention_days)
    config :romulus_elixir, :backup, retention_days: days
  end
  
  if backup_schedule = System.get_env("ROMULUS_BACKUP_SCHEDULE") do
    config :romulus_elixir, :backup, schedule: backup_schedule
  end
end

# Alerting configuration from environment
if System.get_env("ROMULUS_ALERTING_ENABLED") == "true" do
  config :romulus_elixir, :alerting, enabled: true
  
  # Email alerting
  if smtp_server = System.get_env("ROMULUS_SMTP_SERVER") do
    from_email = System.get_env("ROMULUS_FROM_EMAIL", "romulus@localhost")
    
    config :romulus_elixir, :alerting,
      channels: [
        {:email, %{smtp_server: smtp_server, from: from_email}}
      ]
  end
  
  # Slack alerting
  if slack_webhook = System.get_env("ROMULUS_SLACK_WEBHOOK_URL") do
    config :romulus_elixir, :alerting,
      channels: [
        {:email, %{smtp_server: System.get_env("ROMULUS_SMTP_SERVER", "localhost"), from: System.get_env("ROMULUS_FROM_EMAIL", "romulus@localhost")}},
        {:slack, %{webhook_url: slack_webhook}}
      ]
  end
end

# Rate limiting configuration from environment
if System.get_env("ROMULUS_RATE_LIMITING_ENABLED") == "true" do
  config :romulus_elixir, :rate_limiting, enabled: true
  
  if max_ops = System.get_env("ROMULUS_MAX_OPS_PER_MINUTE") do
    ops = String.to_integer(max_ops)
    config :romulus_elixir, :rate_limiting, max_ops_per_minute: ops
  end
  
  if max_concurrent = System.get_env("ROMULUS_MAX_CONCURRENT_OPS") do
    concurrent = String.to_integer(max_concurrent)
    config :romulus_elixir, :rate_limiting, max_concurrent_ops: concurrent
  end
end

# Development/debug settings
if System.get_env("ROMULUS_DEBUG") == "true" do
  config :logger, level: :debug
  config :romulus_elixir, :libvirt, verbose_logging: true
end

# Production optimizations
if env == :prod do
  # Ensure secure defaults in production
  config :romulus_elixir,
    executor: [rollback_on_error: true],
    healing: [auto_heal: false],
    security: [require_tls: true, audit_logging: true]
end

# Test environment specific runtime config
if env == :test do
  # Use mocks in test environment
  config :romulus_elixir, :libvirt,
    adapter: RomulusElixir.Test.MockLibvirt
    
  # Disable external services in tests
  config :romulus_elixir,
    monitoring: [metrics_enabled: false, telemetry_enabled: false],
    backup: [enabled: false],
    alerting: [enabled: false],
    rate_limiting: [enabled: false]
end