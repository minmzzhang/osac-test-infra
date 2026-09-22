#!/usr/bin/env bash
#
# Tear down the virtual agentless_net fabric and clean up its ConfigMap.
# Idempotent — safe to re-run.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="${SCRIPT_DIR}/.."

MGMT_BRIDGE="${MGMT_BRIDGE:-br-agent-mgmt}"
KUBECONFIG="${KUBECONFIG:-/root/labs/osac/deploy/auth/kubeconfig}"
OSAC_NAMESPACE="${OSAC_NAMESPACE:-osac}"
LAB_NAME="agentless-net-lab"
TOPO_FILE="${INFRA_DIR}/agentless-net-lab.clab.yml"
CONTAINERLAB="${CONTAINERLAB:-containerlab}"

info() { echo "==> $*"; }

# ---------- destroy containerlab ----------

if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "clab-${LAB_NAME}"; then
    info "Destroying containerlab topology..."
    ${CONTAINERLAB} destroy -t "$TOPO_FILE" 2>/dev/null || true
else
    info "Containerlab not running — skipping"
fi

# ---------- destroy management bridge ----------

if ip link show "$MGMT_BRIDGE" &>/dev/null; then
    ip link del "$MGMT_BRIDGE" 2>/dev/null || true
    info "Removed bridge ${MGMT_BRIDGE}"
fi

# ---------- clean up inventory ConfigMap ----------

KUBECONFIG="$KUBECONFIG" oc delete configmap agentless-net-inventory \
    -n "$OSAC_NAMESPACE" --ignore-not-found 2>/dev/null || true
info "Cleaned up inventory ConfigMap"

info "destroy-fabric complete."
