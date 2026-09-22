#!/usr/bin/env bash
#
# Install prerequisites for the existing ocp-labs management hub.
# Idempotent — safe to re-run.
#
set -euo pipefail

info() { echo "==> $*"; }

# ---------- Docker (needed by containerlab) ----------

if ! command -v docker &>/dev/null; then
    info "Installing Docker..."
    dnf install -y dnf-plugins-core
    dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    dnf install -y docker-ce docker-ce-cli containerd.io
    systemctl enable --now docker
else
    info "Docker already installed"
fi

# ---------- Containerlab ----------

if ! command -v containerlab &>/dev/null; then
    info "Installing containerlab..."
    bash -c "$(curl -sL https://get.containerlab.dev)"
else
    info "Containerlab already installed"
fi

# ---------- KVM / libvirt ----------

if ! command -v virsh &>/dev/null; then
    info "Installing libvirt/KVM..."
    dnf install -y qemu-kvm libvirt virt-install
    systemctl enable --now libvirtd
else
    info "libvirt already installed"
fi

# ---------- Ansible ----------

if ! command -v ansible-playbook &>/dev/null; then
    info "Installing Ansible..."
    dnf install -y ansible-core
fi

# ---------- Other tools ----------

for tool in git sshpass envsubst jq; do
    if ! command -v "$tool" &>/dev/null; then
        info "Installing ${tool}..."
        dnf install -y "$tool" || pip3 install "$tool" 2>/dev/null || true
    fi
done

info "setup-infra complete."
