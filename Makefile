# Romulus Infrastructure Automation Makefile
# Powered by Elixir

.PHONY: help
help: ## Show this help message
	@echo "Romulus Infrastructure Management"
	@echo "================================="
	@echo ""
	@echo "Available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Commands:"
	@echo "  make migrate-check   - Check system readiness"
	@echo "  make migrate-plan    - Show infrastructure plan"
	@echo "  make migrate-import  - Import existing state"
	@echo ""
	@echo "Environment: $(INFRA_BACKEND)"

# Infrastructure backend
INFRA_BACKEND = elixir

# Paths
ELIXIR_DIR = romulus_elixir

# Colors for output
RED = \033[0;31m
GREEN = \033[0;32m
YELLOW = \033[1;33m
NC = \033[0m # No Color

##@ Infrastructure Management

.PHONY: plan
plan: ## Show infrastructure plan
	@echo "$(GREEN)Using Elixir backend$(NC)"
	cd $(ELIXIR_DIR) && mix romulus.plan

.PHONY: apply
apply: ## Apply infrastructure changes
	@echo "$(GREEN)Using Elixir backend$(NC)"
	cd $(ELIXIR_DIR) && mix romulus.apply

.PHONY: destroy
destroy: ## Destroy infrastructure
	@echo "$(GREEN)Using Elixir backend$(NC)"
	cd $(ELIXIR_DIR) && mix romulus.destroy

.PHONY: validate
validate: ## Validate configuration
	cd $(ELIXIR_DIR) && mix compile --warnings-as-errors
	cd $(ELIXIR_DIR) && mix romulus.render-cloudinit

##@ Kubernetes Management

.PHONY: k8s-bootstrap
k8s-bootstrap: ## Bootstrap Kubernetes cluster
	@echo "$(GREEN)Bootstrapping Kubernetes cluster...$(NC)"
	cd $(ELIXIR_DIR) && mix romulus.k8s.bootstrap

.PHONY: k8s-status
k8s-status: ## Check Kubernetes cluster status
	kubectl get nodes
	kubectl get pods --all-namespaces

##@ Migration Tools

.PHONY: migrate-check
migrate-check: ## Check system readiness
	@echo "$(YELLOW)Checking system readiness...$(NC)"
	@echo ""
	@echo "1. Checking infrastructure state..."
	@echo "   No legacy state to check"
	@echo ""
	@echo "2. Checking Elixir setup..."
	@cd $(ELIXIR_DIR) && mix deps.get --only prod 2>/dev/null && echo "   ✓ Elixir dependencies installed" || echo "   ✗ Missing dependencies"
	@cd $(ELIXIR_DIR) && mix compile --warnings-as-errors 2>/dev/null && echo "   ✓ Elixir code compiles" || echo "   ✗ Compilation errors"
	@test -f $(ELIXIR_DIR)/romulus.yaml && echo "   ✓ Config file exists" || echo "   ✗ Config file missing"
	@echo ""
	@echo "3. Checking libvirt..."
	@virsh list --all 2>/dev/null | grep -q k8s && echo "   ✓ Existing VMs found" || echo "   ✓ No existing VMs"
	@virsh net-list --all 2>/dev/null | grep -q k8s && echo "   ✓ Existing network found" || echo "   ✓ No existing network"
	@echo ""
	@echo "$(GREEN)System ready!$(NC)"

.PHONY: migrate-plan
migrate-plan: ## Show infrastructure plan
	@echo "$(GREEN)Infrastructure Plan$(NC)"
	cd $(ELIXIR_DIR) && mix romulus.plan

.PHONY: migrate-import
migrate-import: ## Import existing state to Elixir
	@echo "$(YELLOW)Importing state...$(NC)"
	cd $(ELIXIR_DIR) && mix romulus.import-state

.PHONY: migrate-convert
migrate-convert: ## Convert configuration to romulus.yaml
	@echo "$(YELLOW)Converting configuration...$(NC)"
	cd $(ELIXIR_DIR) && mix romulus.convert-config

##@ Development

.PHONY: setup
setup: ## Setup development environment
	@echo "$(GREEN)Setting up development environment...$(NC)"
	cd $(ELIXIR_DIR) && mix deps.get
	cd $(ELIXIR_DIR) && mix compile
	@echo "$(GREEN)Setup complete!$(NC)"

.PHONY: test
test: ## Run tests
	cd $(ELIXIR_DIR) && mix test

.PHONY: test-integration
test-integration: ## Run integration tests
	cd $(ELIXIR_DIR) && mix test.integration

.PHONY: format
format: ## Format code
	cd $(ELIXIR_DIR) && mix format

.PHONY: lint
lint: ## Run linters
	cd $(ELIXIR_DIR) && mix credo --strict
	cd $(ELIXIR_DIR) && mix dialyzer

.PHONY: clean
clean: ## Clean build artifacts
	cd $(ELIXIR_DIR) && mix clean
	cd $(ELIXIR_DIR) && rm -rf _build deps

##@ Ansible Integration

.PHONY: ansible-inventory
ansible-inventory: ## Generate Ansible inventory from infrastructure
	@echo "$(GREEN)Generating Ansible inventory...$(NC)"
	cd $(ELIXIR_DIR) && mix romulus.ansible-inventory > ../infrastructure/ansible/inventories/home-lab/hosts.yml

.PHONY: ansible-playbook
ansible-playbook: ## Run Ansible playbook
	cd infrastructure/ansible && ansible-playbook -i inventories/home-lab/hosts.yml playbooks/site.yml

##@ Monitoring

.PHONY: logs
logs: ## Show infrastructure logs
	cd $(ELIXIR_DIR) && tail -f /tmp/romulus_*.log

.PHONY: metrics
metrics: ## Show infrastructure metrics
	@echo "$(GREEN)Infrastructure Metrics:$(NC)"
	@virsh list --all | tail -n +3 | wc -l | xargs echo "  VMs:"
	@virsh net-list --all | tail -n +3 | wc -l | xargs echo "  Networks:"
	@virsh pool-list --all | tail -n +3 | wc -l | xargs echo "  Storage Pools:"

##@ Utilities

.PHONY: ssh-master
ssh-master: ## SSH to first master node
	ssh debian@10.10.10.11

.PHONY: ssh-worker
ssh-worker: ## SSH to first worker node
	ssh debian@10.10.10.21

.PHONY: console
console: ## Open interactive console
	cd $(ELIXIR_DIR) && iex -S mix

.PHONY: backup
backup: ## Backup infrastructure state
	@echo "$(GREEN)Backing up infrastructure state...$(NC)"
	mkdir -p backups/$(shell date +%Y%m%d_%H%M%S)
	cd $(ELIXIR_DIR) && mix romulus.export-state > backups/$(shell date +%Y%m%d_%H%M%S)/elixir-state.json
	@echo "$(GREEN)Backup complete!$(NC)"

# Default target
.DEFAULT_GOAL := help
