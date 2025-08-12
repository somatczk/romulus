import Config

# Test environment configuration for RomulusElixir
# This configuration is used during automated testing

# Test application settings
config :romulus_elixir,
  # Test configuration paths - use fixtures
  default_config_paths: [
    "test/fixtures/romulus.yaml",
    "test/fixtures/test_config.yaml"
  ],
  
  # Test executor configuration
  executor: [
    default_mode: :serial,     # Always serial for predictable testing
    default_timeout: 30_000,   # Short timeout for fast test feedback
    rollback_on_error: false,  # Don't rollback in tests unless explicitly tested
    continue_on_error: false
  ],
  
  # Test planner configuration
  planner: [
    validate_plans: false,     # Skip validation for faster tests
    optimize_plans: false,     # No optimization for simpler test debugging
    max_parallel_actions: 1    # Sequential for deterministic tests
  ],
  
  # Test health check configuration
  health_check: [
    check_interval: 10,        # Very frequent checks for testing
    check_timeout: 5,          # Short timeout
    auto_fix: false,           # Never auto-fix in tests
    ping_timeout: 1,           # Very short ping timeout
    max_retries: 1             # Minimal retries for fast tests
  ],
  
  # Test healing configuration
  healing: [
    enabled: false,            # Disable healing by default in tests
    check_interval: 60,
    max_attempts: 1,
    retry_delay: 1,            # Minimal delay for fast tests
    auto_heal: false,
    safe_mode: true
  ],
  
  # Test storage configuration - use temp directories
  storage: [
    default_pool_path: "/tmp/romulus-test-pools",
    default_pool_type: "dir",
    default_volume_format: "qcow2",
    cleanup_temp_files: true
  ],
  
  # Test VM defaults - minimal resources
  vm: [
    default_memory: 512,       # Minimal memory for tests
    default_vcpus: 1,
    default_disk_size: 1073741824,  # 1GB for tests
    default_arch: "x86_64",
    default_os_type: "hvm"
  ],
  
  # Test Kubernetes settings - fast timeouts
  kubernetes: [
    default_version: "1.28",
    default_cni: "flannel",
    bootstrap_timeout: 120,    # 2 minutes for tests
    node_ready_timeout: 60     # 1 minute for tests
  ]

# Test logging - capture all levels but minimize output
config :logger,
  level: :debug,
  backends: [:console],
  compile_time_purge_matching: []

config :logger, :console,
  level: :warn,              # Only show warnings and errors during tests
  format: "[$level] $message\n",
  metadata: [],
  colors: [enabled: false]   # Disable colors for test output

# Test-specific libvirt configuration
config :romulus_elixir, :libvirt,
  # Mock adapter for most tests
  adapter: RomulusElixir.Test.MockLibvirt,
  
  # Very short timeouts for tests
  virsh_timeout: 5_000,
  
  # Disable verbose logging in tests
  verbose_logging: false,
  
  # Test libvirt URI (won't be used with mock)
  uri: "test:///default"

# Test database configuration (if using a database for state)
config :romulus_elixir, :database,
  # Use in-memory database for tests
  adapter: :memory,
  pool_size: 1

# Test security settings - relaxed for testing
config :romulus_elixir, :security,
  require_tls: false,
  config_file_permissions: 0o644,  # Relaxed for tests
  ssh_key_permissions: 0o644,      # Relaxed for tests
  audit_logging: false
  
# Test monitoring - disabled
config :romulus_elixir, :monitoring,
  metrics_enabled: false,
  telemetry_enabled: false
  
# Test backup - disabled
config :romulus_elixir, :backup,
  enabled: false
  
# Test alerting - disabled
config :romulus_elixir, :alerting,
  enabled: false
  
# Test rate limiting - disabled
config :romulus_elixir, :rate_limiting,
  enabled: false

# ExUnit configuration
config :ex_unit,
  # Capture log messages during tests
  capture_log: true,
  
  # Run tests in parallel by default
  async: true,
  
  # Test timeout
  timeout: 30_000,
  
  # Maximum test cases to run in parallel
  max_cases: System.schedulers_online(),
  
  # Exclude slow tests by default
  exclude: [:slow, :integration],
  
  # Test formatters
  formatters: [ExUnit.CLIFormatter],
  
  # Colors in test output
  colors: [
    enabled: true,
    success: :green,
    invalid: :yellow,
    skipped: :yellow,
    failure: :red
  ]

# Mock configuration for testing
config :romulus_elixir, :mocks,
  # Enable mocking in test environment
  enabled: true,
  
  # Mock external system calls
  mock_system_calls: true,
  
  # Mock libvirt operations
  mock_libvirt: true,
  
  # Mock SSH operations
  mock_ssh: true,
  
  # Mock file system operations
  mock_filesystem: false,  # Usually we want real file operations in tests
  
  # Mock network operations
  mock_network: true

# Test fixtures configuration
config :romulus_elixir, :fixtures,
  # Base directory for test fixtures
  base_dir: "test/fixtures",
  
  # Temporary directory for test files
  temp_dir: "/tmp/romulus-test",
  
  # Whether to clean up fixtures after tests
  cleanup: true

# Property-based testing configuration (if using StreamData)
config :stream_data,
  # Maximum shrinking attempts
  max_shrinking_attempts: 100,
  
  # Initial data size
  initial_size: 1,
  
  # Maximum data size
  max_size: 50

# Test coverage configuration (if using ExCoveralls)
config :excoveralls,
  # Coverage tool
  tool: ExCoveralls,
  
  # Test coverage options
  test_coverage: [
    tool: ExCoveralls,
    summary: [threshold: 80],
    ignore_modules: [
      # Ignore generated modules
      ~r/\.gen$/,
      # Ignore test support modules
      ~r/Test\./,
      # Ignore mock modules
      ~r/Mock/
    ]
  ]