import Config

# Production environment configuration for RomulusElixir
# This configuration is used in production deployments

# Production application settings
config :romulus_elixir,
  # Production configuration file paths
  default_config_paths: [
    "/etc/romulus/romulus.yaml",
    "/opt/romulus/romulus.yaml",
    "romulus.yaml"
  ],
  
  # Production executor configuration
  executor: [
    default_mode: :parallel,  # Use parallel execution for performance
    default_timeout: 600_000,  # 10 minute timeout for production operations
    rollback_on_error: true,   # Always rollback on error in production
    continue_on_error: false   # Stop on first error for safety
  ],
  
  # Production planner configuration
  planner: [
    validate_plans: true,      # Always validate plans in production
    optimize_plans: true,      # Optimize for performance
    max_parallel_actions: 8    # Higher parallelism for production
  ],
  
  # Production health check configuration
  health_check: [
    check_interval: 300,       # Check every 5 minutes
    check_timeout: 60,         # Longer timeout for production
    auto_fix: false,           # Never auto-fix without human approval
    ping_timeout: 10,          # More generous ping timeout
    max_retries: 5             # More retries for production reliability
  ],
  
  # Production healing configuration
  healing: [
    enabled: true,
    check_interval: 900,       # Check every 15 minutes
    max_attempts: 5,           # More attempts for production
    retry_delay: 120,          # 2 minute delay between attempts
    auto_heal: false,          # Require manual approval for healing
    safe_mode: true            # Always use safe mode in production
  ],
  
  # Production storage configuration
  storage: [
    default_pool_path: "/var/lib/libvirt/images",
    default_pool_type: "dir",
    default_volume_format: "qcow2",
    cleanup_temp_files: true
  ],
  
  # Production VM defaults
  vm: [
    default_memory: 4096,      # 4GB default for production
    default_vcpus: 2,
    default_disk_size: 42949672960,  # 40GB for production
    default_arch: "x86_64",
    default_os_type: "hvm"
  ],
  
  # Production Kubernetes settings
  kubernetes: [
    default_version: "1.28",
    default_cni: "flannel",
    bootstrap_timeout: 1800,   # 30 minutes for production
    node_ready_timeout: 600    # 10 minutes for node ready
  ]

# Production logging - structured and less verbose
config :logger,
  level: :info,
  compile_time_purge_matching: [
    [level_lower_than: :info]
  ]

config :logger, :console,
  level: :info,
  format: "$time [$level] $metadata$message\n",
  metadata: [:pid],
  colors: [enabled: false]  # Disable colors for production logs

# Production-specific libvirt configuration
config :romulus_elixir, :libvirt,
  # Production timeouts
  virsh_timeout: 120_000,    # 2 minute timeout for production
  
  # Disable verbose logging in production
  verbose_logging: false,
  
  # Production libvirt URI
  uri: "qemu:///system"

# Production security settings
config :romulus_elixir, :security,
  # Require encrypted connections
  require_tls: true,
  
  # File permissions for sensitive files
  config_file_permissions: 0o600,
  ssh_key_permissions: 0o600,
  
  # Audit logging
  audit_logging: true,
  audit_log_path: "/var/log/romulus/audit.log"

# Production monitoring and metrics
config :romulus_elixir, :monitoring,
  # Enable metrics collection
  metrics_enabled: true,
  
  # Metrics export format
  metrics_format: :prometheus,
  
  # Metrics endpoint
  metrics_port: 9090,
  
  # Health check endpoint
  health_check_port: 8080,
  
  # Enable telemetry
  telemetry_enabled: true

# Production backup configuration
config :romulus_elixir, :backup,
  # Enable automatic state backups
  enabled: true,
  
  # Backup directory
  backup_dir: "/var/lib/romulus/backups",
  
  # Backup retention (days)
  retention_days: 30,
  
  # Backup schedule (cron format)
  schedule: "0 2 * * *",  # Daily at 2 AM
  
  # Backup compression
  compress: true

# Production alerting configuration
config :romulus_elixir, :alerting,
  # Enable alerting
  enabled: true,
  
  # Alert channels
  channels: [
    {:email, %{smtp_server: "localhost", from: "romulus@localhost"}},
    {:slack, %{webhook_url: {:system, "SLACK_WEBHOOK_URL"}}}
  ],
  
  # Alert thresholds
  thresholds: %{
    error_rate: 0.05,        # Alert if error rate > 5%
    response_time: 30000,    # Alert if response time > 30s
    disk_usage: 0.85,        # Alert if disk usage > 85%
    memory_usage: 0.90       # Alert if memory usage > 90%
  }

# Production rate limiting
config :romulus_elixir, :rate_limiting,
  # Enable rate limiting
  enabled: true,
  
  # Maximum operations per minute
  max_ops_per_minute: 60,
  
  # Maximum concurrent operations
  max_concurrent_ops: 10