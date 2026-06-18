#!/usr/bin/env bash
# vault-health-check.sh -- 10-point health check for the OSAC Vault instance.
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
export VAULT_ADDR

# Checks 5-8 query authenticated Vault endpoints; source root/admin token.
INIT_JSON="${HOME}/.vault-server/.vault-init.json"
if [[ -f "${INIT_JSON}" ]]; then
    export VAULT_TOKEN
    VAULT_TOKEN=$(jq -r '.root_token' "${INIT_JSON}")
elif [[ -z "${VAULT_TOKEN:-}" ]]; then
    echo "WARNING: No VAULT_TOKEN set and ${INIT_JSON} not found."
    echo "         Authenticated checks (5-8) will fail."
fi

passed=0
failed=0

check() {
    local num="$1" name="$2"
    shift 2
    if "$@" >/dev/null 2>&1; then
        echo "  [PASS] ${num}. ${name}"
        passed=$(( passed + 1 ))
    else
        echo "  [FAIL] ${num}. ${name}"
        failed=$(( failed + 1 ))
    fi
}

echo "=== Vault Health Check ==="
echo ""

# 1. Vault reachable
check 1 "Vault is reachable" vault status -format=json

# 2. Vault unsealed
check 2 "Vault is unsealed" \
    bash -c 'test "$(vault status -format=json | jq -r .sealed)" = "false"'

# 3. Vault initialized
check 3 "Vault is initialized" \
    bash -c 'test "$(vault status -format=json | jq -r .initialized)" = "true"'

# 4. Vault version reported
check 4 "Vault version reported" \
    bash -c 'vault status -format=json | jq -e .version'

# 5. JWT auth enabled
check 5 "JWT auth method enabled" \
    bash -c 'vault auth list -format=json | jq -e ".\"jwt/\""'

# 6. osac-e2e role exists
check 6 "osac-e2e role exists" \
    vault read auth/jwt/role/osac-e2e

# 7. osac-e2e policy exists
check 7 "osac-e2e policy exists" \
    vault policy read osac-e2e

# 8. KV v2 at secret/
check 8 "KV v2 secrets engine at secret/" \
    bash -c 'vault secrets list -format=json | jq -e ".\"secret/\""'

# 9. systemd vault.service active
check 9 "vault.service is active" \
    systemctl --user is-active vault.service

# 10. backup timer active
check 10 "vault-backup.timer is active" \
    systemctl --user is-active vault-backup.timer

echo ""
echo "=== Results: ${passed} passed, ${failed} failed ==="

if (( failed > 0 )); then
    exit 1
fi
