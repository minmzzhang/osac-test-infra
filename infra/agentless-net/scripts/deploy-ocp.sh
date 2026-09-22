#!/usr/bin/env bash
set -euo pipefail
cat >&2 <<'EOF'
The management hub is created by ocp-labs.
Do not run deploy-ocp.sh in the Beaker agentless_net workflow.
Use KUBECONFIG=/root/labs/osac/deploy/auth/kubeconfig after the hub exists.
EOF
exit 2
