import Config

# Configuration for RomulusElixir application
# This file contains environment-specific configuration for the Elixir infrastructure management tool.

# Application configuration
config :romulus_elixir,
  # Default configuration file paths (in order of preference)
  default_config_paths: [
    "romulus.yaml",
    "config/romulus.yaml", 
    "~/.config/romulus/romulus.yaml",
    "/etc/romulus/romulus.yaml"
  ],
  
  # Libvirt adapter configuration
  libvirt_adapter: RomulusElixir.Libvirt.Virsh,
  
  # Cloud-init template directory
  cloud_init_template_dir: "priv/cloud-init",
  
  # Execution configuration
  executor: [
    # Default execution mode: :serial or :parallel
    default_mode: :serial,
    
    # Default timeout for operations (milliseconds)
    default_timeout: 300_000,
    
    # Whether to rollback on error by default
    rollback_on_error: false,
    
    # Whether to continue on error by default
    continue_on_error: false
  ],
  
  # Planning configuration
  planner: [
    # Whether to validate plans by default
    validate_plans: true,
    
    # Whether to optimize plans by default
    optimize_plans: true,
    
    # Maximum parallel actions
    max_parallel_actions: 4
  ],
  
  # Health check configuration
  health_check: [
    # Default check interval for automated health monitoring (seconds)
    check_interval: 300,
    
    # Timeout for individual health checks (seconds)  
    check_timeout: 30,
    
    # Whether to attempt auto-fix by default
    auto_fix: false,
    
    # Ping timeout for connectivity checks (seconds)
    ping_timeout: 5,
    
    # Maximum retries for failed health checks
    max_retries: 3
  ],
  
  # Healing configuration
  healing: [
    # Whether healing is enabled
    enabled: true,
    
    # Healing check interval (seconds)
    check_interval: 600,
    
    # Maximum healing attempts per issue
    max_attempts: 3,
    
    # Delay between healing attempts (seconds)
    retry_delay: 60,
    
    # Whether to perform automatic healing
    auto_heal: false,
    
    # Safe mode - only perform low-risk healing operations
    safe_mode: true
  ],
  
  # Logging configuration
  log_level: :info,
  
  # Storage configuration defaults
  storage: [
    # Default storage pool path
    default_pool_path: "/var/lib/libvirt/images",
    
    # Default pool type
    default_pool_type: "dir",
    
    # Default volume format
    default_volume_format: "qcow2",
    
    # Cleanup policy for temporary files
    cleanup_temp_files: true
  ],
  
  # Network configuration defaults
  network: [
    # Default network mode
    default_mode: "nat",
    
    # Default DHCP setting
    default_dhcp: true,
    
    # Default DNS setting
    default_dns: true,
    
    # Default domain suffix
    default_domain: "cluster.local"
  ],
  
  # VM configuration defaults
  vm: [
    # Default VM memory (MB)
    default_memory: 2048,
    
    # Default VM vCPUs
    default_vcpus: 2,
    
    # Default disk size (bytes)
    default_disk_size: 21474836480, # 20GB
    
    # Default VM architecture
    default_arch: "x86_64",
    
    # Default OS type
    default_os_type: "hvm"
  ],
  
  # SSH configuration defaults
  ssh: [
    # Default SSH user
    default_user: "ubuntu",
    
    # Default SSH port
    default_port: 22,
    
    # SSH connection timeout (seconds)
    connection_timeout: 30,
    
    # SSH key file permissions
    key_permissions: 0o600
  ],
  
  # Kubernetes configuration defaults
  kubernetes: [
    # Default Kubernetes version
    default_version: "1.28",
    
    # Default CNI plugin
    default_cni: "flannel",
    
    # Default service CIDR
    default_service_cidr: "10.96.0.0/12",
    
    # Default pod CIDR
    default_pod_cidr: "10.244.0.0/16",
    
    # Kubernetes bootstrap timeout (seconds)
    bootstrap_timeout: 1200,
    
    # Node ready timeout (seconds)
    node_ready_timeout: 300
  ]

# Logger configuration
config :logger,
  level: :info,
  format: "[$level] $message\n",
  compile_time_purge_matching: [
    [level_lower_than: :debug]
  ]

# Logger backends
config :logger, :console,
  level: :info,
  format: "[$level] $message\n",
  metadata: [:request_id]

# Import environment-specific configuration
import_config "#{config_env()}.exs"