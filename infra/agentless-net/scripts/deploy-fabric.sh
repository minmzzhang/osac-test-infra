#!/usr/bin/env bash
# Deploy the virtual agentless_net fabric for the existing ocp-labs hub.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="${SCRIPT_DIR}/.."
MGMT_BRIDGE="${MGMT_BRIDGE:-br-agent-mgmt}"
MGMT_CIDR="${MGMT_CIDR:-192.168.126.0/24}"
MGMT_PREFIX="${MGMT_PREFIX:-192.168.126}"
MGMT_GW="${MGMT_GW:-${MGMT_PREFIX}.1}"
KUBECONFIG="${KUBECONFIG:-/root/labs/osac/deploy/auth/kubeconfig}"
OSAC_NAMESPACE="${OSAC_NAMESPACE:-osac}"
DNS_DOMAIN="${DNS_DOMAIN:-clusters.example.com}"
COLLECTIONS_ROOT="${ANSIBLE_COLLECTIONS_PATH:-/root/github/osac/osac-aap/vendor}"
CONTAINERLAB="${CONTAINERLAB:-containerlab}"
TOPO_FILE="${INFRA_DIR}/agentless-net-lab.clab.yml"
NET_NODE="clab-agentless-net-lab-net-node"
UPSTREAM_ROUTER="clab-agentless-net-lab-upstream-router"

info() { echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

for command in docker "$CONTAINERLAB" ip iptables getent envsubst; do
    command -v "$command" >/dev/null 2>&1 || die "required command not found: $command"
done
[ -f "$TOPO_FILE" ] || die "topology file not found: $TOPO_FILE"
[ -d "$COLLECTIONS_ROOT/ansible_collections/ansible_network/network_runner" ] || die "network_runner collection not found under $COLLECTIONS_ROOT"

cat > "${INFRA_DIR}/.agentless-net.env" <<EOF
MGMT_BRIDGE=${MGMT_BRIDGE}
MGMT_CIDR=${MGMT_CIDR}
MGMT_PREFIX=${MGMT_PREFIX}
MGMT_GW=${MGMT_GW}
KUBECONFIG=${KUBECONFIG}
OSAC_NAMESPACE=${OSAC_NAMESPACE}
DNS_DOMAIN=${DNS_DOMAIN}
ANSIBLE_COLLECTIONS_PATH=${COLLECTIONS_ROOT}
EOF

{
    echo '### ip route'
    ip route
    echo '### ip link'
    ip link show
    echo '### iptables'
    iptables-save
} | tee /tmp/beaker-network-before.txt >/dev/null

if ! docker ps --format '{{.Names}}' | grep -q '^clab-agentless-net-lab-leaf-1$'; then
    info "Deploying Containerlab topology..."
    env MGMT_BRIDGE="$MGMT_BRIDGE" MGMT_CIDR="$MGMT_CIDR" MGMT_PREFIX="$MGMT_PREFIX" MGMT_GW="$MGMT_GW" "$CONTAINERLAB" deploy -t "$TOPO_FILE"
else
    info "Containerlab topology already running"
fi

info "Checking topology containers..."
docker ps --format '{{.Names}}\t{{.Status}}' | grep 'clab-agentless-net-lab-' || true

RESOLVED_INVENTORY="$(mktemp)"
trap 'rm -f "$RESOLVED_INVENTORY"' EXIT
MGMT_BRIDGE="$MGMT_BRIDGE" MGMT_CIDR="$MGMT_CIDR" MGMT_PREFIX="$MGMT_PREFIX" MGMT_GW="$MGMT_GW" envsubst < "${INFRA_DIR}/inventory/inventory.yml" > "$RESOLVED_INVENTORY"

info "Configuring switch trunks..."
ANSIBLE_COLLECTIONS_PATH="$COLLECTIONS_ROOT" ansible-playbook -i "$RESOLVED_INVENTORY" "${INFRA_DIR}/playbooks/configure_network.yml"

info "Temporarily adding Docker networking for Alpine packages..."
docker network connect bridge "$NET_NODE" 2>/dev/null || true
docker network connect bridge "$UPSTREAM_ROUTER" 2>/dev/null || true
ALPINE_IP="$(getent ahostsv4 dl-cdn.alpinelinux.org | awk 'NR==1{print $1}')"
[ -n "$ALPINE_IP" ] || die "could not resolve the Alpine CDN on the Beaker host"
for container in "$NET_NODE" "$UPSTREAM_ROUTER"; do
    docker exec "$container" sh -c "printf '%s dl-cdn.alpinelinux.org\n' '$ALPINE_IP' >> /etc/hosts"
done
docker exec "$NET_NODE" apk update
docker exec "$NET_NODE" apk add --no-cache iptables iproute2 python3 openssh frr dnsmasq
docker exec "$UPSTREAM_ROUTER" apk update
docker exec "$UPSTREAM_ROUTER" apk add --no-cache frr iptables
docker network disconnect bridge "$NET_NODE" 2>/dev/null || true
docker network disconnect bridge "$UPSTREAM_ROUTER" 2>/dev/null || true

info "Configuring routing and NAT..."
docker exec "$NET_NODE" ip addr replace 10.0.0.30/24 dev eth1
docker exec "$NET_NODE" ip addr replace 10.253.0.1/30 dev eth2
docker exec "$NET_NODE" ip link set eth2 up
docker exec "$NET_NODE" sysctl -w net.ipv4.ip_forward=1
docker exec "$NET_NODE" sh -c 'iptables -t nat -C POSTROUTING -o eth2 -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o eth2 -j MASQUERADE'
docker exec "$UPSTREAM_ROUTER" ip addr replace 10.253.0.2/30 dev eth1
docker exec "$UPSTREAM_ROUTER" ip link set eth1 up
docker exec "$UPSTREAM_ROUTER" sysctl -w net.ipv4.ip_forward=1
docker exec "$UPSTREAM_ROUTER" sh -c 'iptables -t nat -C POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE'
docker exec "$NET_NODE" ip route replace default via 10.253.0.2

info "Starting FRR..."
for container in "$NET_NODE" "$UPSTREAM_ROUTER"; do
    docker exec "$container" sh -c 'mkdir -p /etc/frr; printf "%s\n" "frr version 8.4" "frr defaults traditional" "hostname agentless-net" "log stdout" "service integrated-vtysh-config" "line vty" > /etc/frr/frr.conf; printf "%s\n" "zebra=yes" "bgpd=yes" > /etc/frr/daemons; /usr/sbin/frrinit.sh start 2>/dev/null || true'
done

info "Configuring dnsmasq on ${NET_NODE}..."
docker exec "$NET_NODE" sh -c "cat > /etc/dnsmasq.conf" <<EOF
no-resolv
server=10.45.248.15
interface=eth0
interface=eth1
listen-address=${MGMT_PREFIX}.30
listen-address=10.0.0.30
bind-interfaces
domain-needed
bogus-priv
local=/${DNS_DOMAIN}/
no-dhcp-interface=eth0
dhcp-range=interface:eth1,10.0.0.100,10.0.0.200,255.255.255.0,12h
dhcp-option=3,10.0.0.30
dhcp-option=6,10.0.0.30
host-record=api.test.${DNS_DOMAIN},192.168.100.10
address=/.apps.test.${DNS_DOMAIN}/192.168.100.11
log-queries
log-dhcp
EOF
docker exec "$NET_NODE" dnsmasq --test
docker exec "$NET_NODE" pkill dnsmasq 2>/dev/null || true
docker exec -d "$NET_NODE" dnsmasq --keep-in-foreground --log-facility=/var/log/dnsmasq.log

info "Publishing resolved agentless_net inventory to ${OSAC_NAMESPACE}..."
KUBECONFIG="$KUBECONFIG" oc create configmap agentless-net-inventory --from-file=inventory.yml="$RESOLVED_INVENTORY" -n "$OSAC_NAMESPACE" --dry-run=client -o yaml | KUBECONFIG="$KUBECONFIG" oc apply -f -

{
    echo '### ip route'
    ip route
    echo '### ip link'
    ip link show
    echo '### iptables'
    iptables-save
} | tee /tmp/beaker-network-after.txt >/dev/null

info "deploy-fabric complete. Snapshots: /tmp/beaker-network-before.txt and /tmp/beaker-network-after.txt"
