#!/usr/bin/env bash
set -euo pipefail
cat >&2 <<'EOF'
This workflow does not use assisted ISO provisioning.
Prepare managed hosts through the agentless_net DiskImage/AAP workflow
described in osac-caas-helm-install-cookbook.md.
Do not run setup-caas.sh in the Beaker workflow.
EOF
exit 2
