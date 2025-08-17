# Centralized Secret Management Architecture

## Problem Statement

Current setup has secrets in multiple locations that can drift out of sync:
- GitHub repository secrets (for CI/CD)
- `.env` file on homeserver (for runtime)
- Manual synchronization required when rotating secrets

## Recommended Solutions

### Option 1: HashiCorp Vault (Recommended for Production)

**Architecture:**
```
GitHub Actions → Vault Agent → HashiCorp Vault
Homeserver     → Vault Agent → HashiCorp Vault
```

**Benefits:**
- Single source of truth for secrets
- Automatic rotation capabilities  
- Audit logging and access control
- Dynamic secrets for databases
- Encryption in transit and at rest

**Implementation:**
1. Deploy Vault server (can be self-hosted or cloud)
2. Configure Vault agents on homeserver and GitHub runner
3. Use Vault API/CLI for secret retrieval
4. Implement secret rotation workflows

### Option 2: External Secret Operator (Kubernetes-like)

**Architecture:**
```
External Secret Operator → Cloud Provider Secret Manager
                       ↓
                   .env file generation
```

**Providers:**
- AWS Secrets Manager
- Azure Key Vault  
- Google Secret Manager
- HashiCorp Vault

### Option 3: Git-based Secret Management (Simple)

**Architecture:**
```
Encrypted secrets repo → GitHub Actions → Server deployment
                      ↓
                  SOPS/age encryption
```

**Benefits:**
- Version controlled secrets
- GitOps workflow
- Encrypted at rest in git
- Simple tooling (SOPS + age)

## Recommended Implementation: Option 3 (SOPS + age)

Most practical for homeserver setup - balances security with simplicity.

### Components:
- **SOPS** - Encrypts/decrypts YAML/JSON files
- **age** - Modern encryption tool
- **Git repository** - Stores encrypted secrets
- **GitHub Actions** - Automated deployment

### Workflow:
1. Secrets stored in encrypted `.env.encrypted` file
2. GitHub Actions decrypts during deployment
3. Decrypted `.env` deployed to homeserver
4. Services read from local `.env` file
5. Secret rotation via git commits

### File Structure:
```
secrets/
├── .env.encrypted          # SOPS encrypted environment
├── age-key.txt            # age private key (in GitHub secrets)
└── .sops.yaml             # SOPS configuration
```