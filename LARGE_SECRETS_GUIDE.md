# Large Secrets Management Guide

This guide explains how to manage environment variables that exceed GitHub's 48KB secret limit by using GPG encryption and JSON format.

## 🎯 **Overview**

Instead of managing 46+ individual GitHub Secrets, this approach:
1. Converts your `.env.template` to JSON format
2. Encrypts the JSON file using GPG
3. Stores only **one passphrase** as a GitHub Secret
4. Automatically loads all environment variables in workflows

## 🔧 **Setup Process**

### Step 1: Prepare Your Environment Secrets

Run the preparation script to convert `.env.template` to encrypted JSON:

```bash
./scripts/prepare-env-secrets.sh
```

This will:
- Convert `.env.template` to JSON format (required by GitHub Actions)
- Encrypt the JSON file using GPG with AES256 cipher
- Create `secrets-encrypted/homeserver-env-secrets.json.gpg`

Example interaction:
```
Enter passphrase for encryption (will be hidden):
Confirm passphrase:
✅ Environment variables converted to JSON
✅ JSON validation passed
Found 46 environment variables
✅ Environment secrets encrypted successfully!
```

### Step 2: Commit the Encrypted File

```bash
git add secrets-encrypted/homeserver-env-secrets.json.gpg
git commit -m "Add encrypted environment secrets"
git push
```

**⚠️ Important**: Only commit the `.gpg` file, never the unencrypted JSON or `.env` files!

### Step 3: Create GitHub Secret

In your GitHub repository settings, create **one secret**:
- **Name**: `ENV_SECRETS_PASSPHRASE`
- **Value**: The passphrase you used for encryption

### Step 4: Update Your Workflow

Replace your current `deploy.yml` with the new approach:

```yaml
- name: Decrypt Environment Secrets
  run: ./scripts/decrypt-large-secrets.sh homeserver-env-secrets.json
  env:
    LARGE_SECRET_PASSPHRASE_HOMESERVER_ENV_SECRETS_JSON: ${{ secrets.ENV_SECRETS_PASSPHRASE }}

- name: Load Environment Variables
  run: |
    echo "Loading environment variables from decrypted JSON..."
    jq -r 'to_entries[] | "\(.key)=\(.value)"' $HOME/secrets/homeserver-env-secrets.json >> $GITHUB_ENV
```

### Step 5: Remove Individual Secrets

You can now delete all 46+ individual GitHub Secrets since they'll be loaded from the encrypted JSON file.

## 📁 **File Structure**

```
romulus/
├── .env.template                           # Your environment template (not committed with values)
├── secrets-encrypted/
│   └── homeserver-env-secrets.json.gpg     # Encrypted JSON (committed)
├── scripts/
│   ├── prepare-env-secrets.sh              # Convert & encrypt
│   └── decrypt-large-secrets.sh            # Decrypt in workflows
└── .github/workflows/
    └── deploy-with-env-secrets.yml.example # Updated workflow example
```

## 🔄 **Workflow Process**

1. **Checkout** repository code
2. **Decrypt** the environment secrets JSON file using the passphrase
3. **Load** all environment variables into `$GITHUB_ENV`
4. **Deploy** services with all variables available
5. **Cleanup** decrypted files securely

## 🛠️ **Script Details**

### prepare-env-secrets.sh

Converts `.env.template` to encrypted JSON format:

```bash
# Basic usage
./scripts/prepare-env-secrets.sh

# With custom passphrase
./scripts/prepare-env-secrets.sh -p mypassphrase

# Force overwrite existing files
./scripts/prepare-env-secrets.sh -f

# Custom output directory
./scripts/prepare-env-secrets.sh -o /custom/path
```

**Features**:
- Validates JSON format using `jq` (if available)
- Handles special characters in environment values
- Provides detailed file size information
- Secure passphrase confirmation

### decrypt-large-secrets.sh

Decrypts GPG files in GitHub Actions:

```bash
# Decrypt specific file
./scripts/decrypt-large-secrets.sh homeserver-env-secrets.json

# Decrypt all .gpg files
./scripts/decrypt-large-secrets.sh --all

# Verbose output for debugging
./scripts/decrypt-large-secrets.sh -v homeserver-env-secrets.json
```

**Features**:
- GitHub Actions compatible logging
- Secure file permissions (600)
- File integrity validation
- Automatic cleanup on failure

## 📋 **Environment Variables Included**

The encrypted JSON contains all variables from `.env.template`:

### System Configuration
- `TZ`, `PUID`, `PGID`
- `DOMAIN`, `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_DOMAINS`
- `NVME_PATH`, `SSD_PATH`, `HDD_PATH`

### Service Authentication
- `MYSQL_ROOT_PASSWORD`, `REDIS_PASSWORD`, `TS3SERVER_DB_PASSWORD`
- `PLEX_CLAIM`, `QBITTORRENT_PASSWORD`
- `CS2_SERVER_NAME`, `CS2_RCON_PASSWORD`, `CS2_SERVER_PASSWORD`, `STEAM_TOKEN`
- `TS3_SERVER_ADMIN_PASSWORD`, `GF_SECURITY_ADMIN_PASSWORD`

### Resource Limits
- `PLEX_MEMORY_LIMIT`, `PLEX_CPU_LIMIT`
- `CS2_MEMORY_LIMIT`, `CS2_CPU_LIMIT`
- `RUNNER_MEMORY_LIMIT`, `RUNNER_CPU_LIMIT`

### Port Configuration
- All service ports: `PLEX_PORT`, `QBITTORRENT_PORT`, etc.

### Monitoring & Alerting
- `DISCORD_WEBHOOK_URL`, SMTP settings
- `MONITORING_DB_PASSWORD`

### GitHub Runner
- `GITHUB_REPOSITORY`, `GITHUB_RUNNER_TOKEN`, etc.

**Total**: 46+ environment variables in JSON format

## 🔐 **Security Features**

### Encryption
- **Algorithm**: AES256 (industry standard)
- **Format**: GPG symmetric encryption
- **Key Derivation**: PBKDF2 (built into GPG)

### GitHub Actions Security
- **JSON Format**: Required by GitHub Actions for bulk environment loading
- **Secure Loading**: Variables loaded directly into `$GITHUB_ENV`
- **Automatic Cleanup**: Decrypted files securely overwritten and deleted
- **No Logging**: Scripts avoid printing sensitive values

### Best Practices
- Only the passphrase is stored as a GitHub Secret
- Encrypted file can be safely committed to repository
- Temporary files are securely cleaned up
- File permissions set to 600 (owner read/write only)

## 🚀 **Benefits**

### Simplified Management
- ✅ **1 GitHub Secret** instead of 46+
- ✅ **Single source of truth** for all environment variables
- ✅ **Version controlled** encrypted configuration
- ✅ **Easy updates** - just re-encrypt when `.env.template` changes

### Enhanced Security
- ✅ **Strong encryption** with AES256
- ✅ **No secrets in logs** (GitHub doesn't redact large secrets automatically)
- ✅ **Secure cleanup** after use
- ✅ **Proper file permissions**

### Developer Experience
- ✅ **Local development** still uses `.env` file
- ✅ **Production consistency** with same variable names
- ✅ **Automated deployment** with single secret
- ✅ **Clear documentation** of all required variables

## 🔄 **Updating Secrets**

When you need to update environment variables:

1. **Update** `.env.template` with new values
2. **Re-encrypt** using the prepare script:
   ```bash
   ./scripts/prepare-env-secrets.sh -f
   ```
3. **Commit** the updated encrypted file:
   ```bash
   git add secrets-encrypted/homeserver-env-secrets.json.gpg
   git commit -m "Update environment secrets"
   git push
   ```

The passphrase GitHub Secret doesn't need to change unless you want to rotate it.

## 🛡️ **Security Considerations**

### ⚠️ **Important Warnings**

1. **Never commit unencrypted files**
   - `.env` files with real values
   - `homeserver-env-secrets.json` (unencrypted)
   - Any temporary files containing secrets

2. **GitHub doesn't redact large secrets**
   - Ensure scripts don't echo/print decrypted content
   - Use `set +x` to disable debug output when handling secrets
   - Be careful with error messages that might expose values

3. **Passphrase security**
   - Use a strong, unique passphrase
   - Store only in GitHub Secrets (never in code/comments)
   - Consider rotating periodically

### 🔒 **Additional Security Measures**

- Scripts use `set -euo pipefail` for error handling
- Temporary files are securely overwritten with `shred`
- File permissions are restricted to owner only
- JSON validation prevents malformed configurations

## 🆘 **Troubleshooting**

### Common Issues

**"Encrypted file not found"**
```bash
# Ensure file exists and path is correct
ls -la secrets-encrypted/homeserver-env-secrets.json.gpg
```

**"Failed to decrypt"**
```bash
# Check passphrase is correct
gpg --decrypt secrets-encrypted/homeserver-env-secrets.json.gpg
```

**"Invalid JSON format"**
```bash
# Validate JSON structure
jq empty $HOME/secrets/homeserver-env-secrets.json
```

**"Critical variable missing"**
```bash
# Check specific variables exist
jq '.DOMAIN' $HOME/secrets/homeserver-env-secrets.json
```

### Debug Mode

Enable verbose output for troubleshooting:

```bash
./scripts/decrypt-large-secrets.sh -v homeserver-env-secrets.json
```

This will show detailed steps and help identify issues.

## 📞 **Support**

For issues with large secrets management:

1. Check the script output for specific error messages
2. Verify passphrase is correct by testing decryption locally
3. Ensure `.env.template` format is valid (no malformed lines)
4. Validate GitHub Secret name matches script expectations

The large secrets system provides a secure, manageable way to handle all your homeserver environment variables with a single passphrase! 🔐