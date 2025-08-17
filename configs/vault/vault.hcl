# HashiCorp Vault Server Configuration
# 
# Purpose: Main Vault server configuration for secret management
# Features: File storage, HTTP API, Web UI, audit logging

# Storage backend - file system (simple for homeserver)
storage "file" {
  path = "/vault/data"
}

# HTTP listener configuration
listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true  # Disable for internal network, enable for production
}

# API address for agent communication
api_addr = "http://0.0.0.0:8200"
cluster_addr = "http://0.0.0.0:8201"

# Enable Web UI
ui = true

# Logging configuration
log_level = "INFO"
log_file = "/vault/logs/vault.log"
log_rotate_duration = "24h"
log_rotate_max_files = 7

# Disable mlock for containers (requires IPC_LOCK capability)
disable_mlock = true

# Enable performance standby (for clustering, optional)
disable_performance_standby = true

# Plugin directory (for custom auth methods)
plugin_directory = "/vault/plugins"

# Default lease settings
default_lease_ttl = "768h"    # 32 days
max_lease_ttl = "8760h"       # 1 year