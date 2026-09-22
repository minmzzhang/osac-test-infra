#!/usr/bin/env bash
set -euo pipefail
cat >&2 <<'EOF'
Install OSAC with the sequential Helm steps in
osac-caas-helm-install-cookbook.md.
Do not run deploy-osac.sh in the Beaker agentless_net workflow.
The hub kubeconfig is /root/labs/osac/deploy/auth/kubeconfig.
EOF
exit 2
