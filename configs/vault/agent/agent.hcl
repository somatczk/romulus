# Vault Agent Configuration
# 
# Purpose: Automatically authenticate and fetch secrets for services
# Features: Auto-auth, template rendering, secret caching

# Exit after authentication and template rendering
exit_after_auth = false

# PID file for agent management
pid_file = "/vault/agent/vault-agent.pid"

# Auto-authentication using AppRole
auto_auth {
  method "approle" {
    mount_path = "auth/approle"
    config = {
      role_id_file_path = "/vault/agent/role-id"
      secret_id_file_path = "/vault/agent/secret-id"
    }
  }

  sink "file" {
    config = {
      path = "/vault/agent/token"
      mode = 0600
    }
  }
}

# Template for .env file generation
template {
  source      = "/vault/config/env.tpl"
  destination = "/vault/agent/.env"
  perms       = 0600
  command     = "/vault/config/restart-services.sh"
}

# Template for database credentials
template {
  source      = "/vault/config/database.tpl"
  destination = "/vault/agent/database.env"
  perms       = 0600
}

# Cache configuration
cache {
  use_auto_auth_token = true
}

# Vault server connection
vault {
  address = "http://vault:8200"
}

# Logging
log_level = "INFO"
log_file = "/vault/agent/agent.log"