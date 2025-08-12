import Config

# Development environment configuration for RomulusElixir
# This configuration is used during development and testing

# Override application settings for development
config :romulus_elixir,
  # Use test-friendly paths in development
  default_config_paths: [
    "romulus.yaml",
    "test/fixtures/romulus.yaml",
    "config/romulus.dev.yaml"
  ],
  
  # Development executor configuration
  executor: [
    default_mode: :serial,
    default_timeout: 60_000,  # Shorter timeout for development
    rollback_on_error: true,  # Enable rollback for safer development
    continue_on_error: false
  ],
  
  # Development planner configuration
  planner: [
    validate_plans: true,
    optimize_plans: false,  # Disable optimization for clearer debugging
    max_parallel_actions: 2  # Limit parallelism for easier debugging
  ],
  
  # More frequent health checks in development
  health_check: [
    check_interval: 60,  # Check every minute
    check_timeout: 15,
    auto_fix: false,  # Don't auto-fix in development
    ping_timeout: 2,
    max_retries: 2
  ],
  
  # Development healing configuration
  healing: [
    enabled: true,
    check_interval: 120,  # Check every 2 minutes
    max_attempts: 2,
    retry_delay: 30,
    auto_heal: false,  # Never auto-heal in development
    safe_mode: true
  ],
  
  # Development storage paths
  storage: [
    default_pool_path: "/tmp/romulus-dev-pools",
    default_pool_type: "dir",
    default_volume_format: "qcow2",
    cleanup_temp_files: true
  ],
  
  # Development VM defaults (smaller for dev)
  vm: [
    default_memory: 1024,  # 1GB for development
    default_vcpus: 1,
    default_disk_size: 5368709120,  # 5GB for development
    default_arch: "x86_64",
    default_os_type: "hvm"
  ],
  
  # Development Kubernetes settings
  kubernetes: [
    default_version: "1.28",
    default_cni: "flannel",
    bootstrap_timeout: 600,  # 10 minutes for development
    node_ready_timeout: 180  # 3 minutes for development
  ]

# Logger configuration for development
config :logger,
  level: :debug,
  compile_time_purge_matching: [
    [level_lower_than: :debug]
  ]

config :logger, :console,
  level: :debug,
  format: "[$level] $time $metadata $message\n",
  metadata: [:pid, :module, :function, :line],
  colors: [
    debug: :cyan,
    info: :normal,
    warn: :yellow,
    error: :red
  ]

# Development-specific libvirt configuration
config :romulus_elixir, :libvirt,
  # Use shorter timeouts for faster development feedback
  virsh_timeout: 30_000,
  
  # Enable verbose libvirt logging in development
  verbose_logging: true,
  
  # Development libvirt URI (local only)
  uri: "qemu:///system"