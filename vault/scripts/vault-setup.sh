#!/usr/bin/env bash
# vault-setup.sh -- One-time Vault deployment on the OSAC CI runner.
#
# Phases:
#   1.  Create directory layout under ~/.vault-server/
#   2.  Copy config files from this repo
#   3.  Install Quadlet unit + systemd services, start Vault
#   4.  Initialize Vault (3 key shares, threshold 2)
#   5.  Extract unseal keys
#   6.  Unseal Vault
#   7.  Enable KV v2 secrets engine at secret/
#   8.  Enable and configure JWT auth (GitHub OIDC)
#   9.  Create osac-e2e policy and role
#  10.  Enable loginctl linger, enable vault.service + backup timer
#
# Prerequisites:
#   - podman, jq, vault CLI installed
#   - This script is run from the repo root (or REPO_ROOT is set)
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
export VAULT_ADDR

VAULT_HOME="${HOME}/.vault-server"
# Resolve to the vault/ directory: scripts live at vault/scripts/
VAULT_REPO_DIR="${VAULT_REPO_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"

QUADLET_DIR="${HOME}/.config/containers/systemd"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"

###############################################################################
phase() { echo -e "\n==> Phase $1: $2"; }

# Helper: get a field from vault status JSON.
# vault status exits 0 (unsealed), 1 (error), or 2 (sealed/uninitialized),
# so we must suppress its exit code to avoid triggering pipefail.
vault_status_field() {
    (vault status -format=json 2>/dev/null || true) | jq -r ".$1" 2>/dev/null
}
###############################################################################

###############################################################################
# Phase 1: Create directory layout
###############################################################################
phase 1 "Creating directory layout under ${VAULT_HOME}"
mkdir -p "${VAULT_HOME}"/{config,data,logs,scripts,backups}
chmod 700 "${VAULT_HOME}"

# The Vault container runs as uid=100(vault) gid=1000(vault).
# In rootless Podman the user namespace handles UID mapping, so chown
# is only needed (and only works) when running as root.
if [[ "${EUID}" -eq 0 ]]; then
    VAULT_UID=100
    VAULT_GID=1000
    chown "${VAULT_UID}:${VAULT_GID}" "${VAULT_HOME}/data" "${VAULT_HOME}/logs"
fi

###############################################################################
# Phase 2: Copy config files from repo
###############################################################################
phase 2 "Copying config files from repo"
cp "${VAULT_REPO_DIR}/config/vault.hcl" "${VAULT_HOME}/config/vault.hcl"
cp "${VAULT_REPO_DIR}/scripts/vault-unseal.sh" "${VAULT_HOME}/scripts/vault-unseal.sh"
cp "${VAULT_REPO_DIR}/scripts/vault-backup.sh" "${VAULT_HOME}/scripts/vault-backup.sh"
chmod +x "${VAULT_HOME}/scripts/"*.sh

###############################################################################
# Phase 3: Install Quadlet unit + systemd services, start Vault
###############################################################################
phase 3 "Installing Quadlet and systemd units"
mkdir -p "${QUADLET_DIR}" "${SYSTEMD_USER_DIR}"

cp "${VAULT_REPO_DIR}/quadlet/vault.container" "${QUADLET_DIR}/vault.container"
cp "${VAULT_REPO_DIR}/vault-unseal.service"    "${SYSTEMD_USER_DIR}/vault-unseal.service"
cp "${VAULT_REPO_DIR}/vault-backup.service"    "${SYSTEMD_USER_DIR}/vault-backup.service"
cp "${VAULT_REPO_DIR}/vault-backup.timer"      "${SYSTEMD_USER_DIR}/vault-backup.timer"

systemctl --user daemon-reload

echo "Starting vault.service ..."
# On first run, ExecStartPost (unseal) will exit 0 gracefully because Vault
# is not yet initialized.  If it fails for another reason, continue anyway --
# the setup script handles init + unseal in later phases.
systemctl --user start vault.service || true

# Wait for the Vault API to become reachable.
# vault status exits 0 (unsealed), 1 (error), or 2 (sealed/uninitialized).
# Any JSON response means the server is up.
echo "Waiting for Vault to be reachable ..."
vault_reachable=false
for _ in $(seq 1 30); do
    if [[ "$(vault_status_field 'type')" != "" && "$(vault_status_field 'type')" != "null" ]]; then
        vault_reachable=true
        break
    fi
    sleep 1
done

if [[ "${vault_reachable}" != "true" ]]; then
    echo "ERROR: Vault not reachable after 30 seconds." >&2
    echo "Check 'systemctl --user status vault.service' and 'podman logs systemd-vault'." >&2
    exit 1
fi

###############################################################################
# Phase 4: Initialize Vault
###############################################################################
phase 4 "Initializing Vault (3 key shares, threshold 2)"

init_status=$(vault_status_field 'initialized')
if [[ "${init_status}" == "true" ]]; then
    echo "Vault is already initialized -- skipping."
else
    vault operator init \
        -key-shares=3 \
        -key-threshold=2 \
        -format=json > "${VAULT_HOME}/.vault-init.json"
    chmod 0600 "${VAULT_HOME}/.vault-init.json"
    echo "Init output saved to ${VAULT_HOME}/.vault-init.json (mode 0600)"
    echo "IMPORTANT: Back up this file securely, then delete it from the runner."
fi

###############################################################################
# Phase 5: Extract unseal keys
###############################################################################
phase 5 "Extracting unseal keys"

if [[ -f "${VAULT_HOME}/.vault-init.json" ]]; then
    jq -r '.unseal_keys_b64[]' "${VAULT_HOME}/.vault-init.json" \
        > "${VAULT_HOME}/.unseal-keys"
    chmod 0600 "${VAULT_HOME}/.unseal-keys"
    echo "Unseal keys written to ${VAULT_HOME}/.unseal-keys (mode 0600)"
else
    echo "No init JSON found -- assuming unseal keys already exist."
fi

###############################################################################
# Phase 6: Unseal Vault
###############################################################################
phase 6 "Unsealing Vault"
"${VAULT_HOME}/scripts/vault-unseal.sh"

###############################################################################
# Phase 7: Enable KV v2 secrets engine
###############################################################################
phase 7 "Enabling KV v2 secrets engine at secret/"

# Authenticate with the root token from init
if [[ -f "${VAULT_HOME}/.vault-init.json" ]]; then
    export VAULT_TOKEN
    VAULT_TOKEN=$(jq -r '.root_token' "${VAULT_HOME}/.vault-init.json")
elif [[ -z "${VAULT_TOKEN:-}" ]]; then
    echo "ERROR: No VAULT_TOKEN set and ${VAULT_HOME}/.vault-init.json not found." >&2
    echo "Export VAULT_TOKEN before re-running, or provide the init JSON." >&2
    exit 1
fi

# Check if already enabled
if vault secrets list -format=json 2>/dev/null | jq -e '."secret/"' >/dev/null 2>&1; then
    echo "KV v2 at secret/ already enabled -- skipping."
else
    vault secrets enable -path=secret kv-v2
    echo "KV v2 enabled at secret/"
fi

###############################################################################
# Phase 8: Enable and configure JWT auth (GitHub OIDC)
###############################################################################
phase 8 "Configuring JWT auth for GitHub OIDC"

if vault auth list -format=json 2>/dev/null | jq -e '."jwt/"' >/dev/null 2>&1; then
    echo "JWT auth already enabled -- reconfiguring."
else
    vault auth enable jwt
    echo "JWT auth enabled."
fi

vault write auth/jwt/config \
    oidc_discovery_url="https://token.actions.githubusercontent.com" \
    bound_issuer="https://token.actions.githubusercontent.com"

echo "JWT auth configured with GitHub Actions OIDC provider."

###############################################################################
# Phase 9: Create osac-e2e policy and role
###############################################################################
phase 9 "Creating osac-e2e policy and role"

vault policy write osac-e2e - <<'POLICY'
# Allow reading e2e test secrets
path "secret/data/osac/e2e/*" {
  capabilities = ["read"]
}
POLICY
echo "Policy 'osac-e2e' created."

vault write auth/jwt/role/osac-e2e - <<'ROLE'
{
  "role_type": "jwt",
  "bound_claims": {
    "repository_owner": "osac-project",
    "environment": "e2e-test"
  },
  "bound_audiences": ["https://github.com/osac-project"],
  "user_claim": "repository",
  "token_policies": ["osac-e2e"],
  "token_ttl": "60m",
  "token_max_ttl": "120m"
}
ROLE

echo "Role 'osac-e2e' created (bound to osac-project org + e2e-test environment, 60m TTL)."

###############################################################################
# Phase 10: Enable linger, enable services
###############################################################################
phase 10 "Enabling loginctl linger and systemd services"

loginctl enable-linger "$(whoami)" 2>/dev/null || true

# vault.service is a Quadlet-generated unit; it is enabled automatically
# via its [Install] WantedBy in the .container file and cannot be
# enabled with systemctl.  We only need to enable the backup timer.
systemctl --user enable vault-backup.timer
systemctl --user start vault-backup.timer

echo ""
echo "============================================"
echo "  Vault setup complete!"
echo "============================================"
echo ""
echo "Next steps:"
echo "  1. Back up ${VAULT_HOME}/.vault-init.json securely"
echo "  2. Delete the init JSON from this machine"
echo "  3. Run vault-health-check.sh to verify"
echo "  4. Populate e2e secrets at secret/osac/e2e/"
echo ""
