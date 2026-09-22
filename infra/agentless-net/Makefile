# ─── Variables ──────────────────────────────────────────────────────

OSAC_DEPLOY_MODE ?= fresh
EXTRA_VARS ?=
ENV_INFRA := .env.infra
SCRIPTS := scripts

KUBECONFIG ?= /root/labs/osac/deploy/auth/kubeconfig
OSAC_NAMESPACE ?= osac
OSAC_PULL_SECRET_PATH ?= /root/pull-secret

export KUBECONFIG OSAC_NAMESPACE OSAC_PULL_SECRET_PATH

# ─── Contract targets ──────────────────────────────────────────────
#
# Called individually from the workflow or command line.
# The hub is created by ocp-labs. This repository configures the virtual fabric.

setup-infra:
	@echo "=== Installing prerequisites ==="
	$(SCRIPTS)/setup-infra.sh

deploy-ocp:
	@echo "=== The OCP hub must be created by ocp-labs ==="
	$(SCRIPTS)/deploy-ocp.sh

deploy-osac:
	@echo "=== Install OSAC with the cookbook Helm steps ==="
	$(SCRIPTS)/deploy-osac.sh

deploy-fabric:
	@echo "=== Deploying containerlab topology, configuring switches, BGP ==="
	$(SCRIPTS)/deploy-fabric.sh

setup-caas:
	@echo "=== Managed hosts use the DiskImage/AAP path for this workflow ==="
	$(SCRIPTS)/setup-caas.sh

test-e2e:
	@echo "=== Running E2E tests ==="
	$(SCRIPTS)/test-e2e.sh

destroy-osac:
	@echo "=== Tearing down OSAC ==="
	$(SCRIPTS)/destroy-osac.sh
	@rm -f $(ENV_INFRA)

destroy-ocp:
	@echo "=== Tearing down OCP ==="
	$(SCRIPTS)/destroy-ocp.sh
	@rm -f $(ENV_INFRA)

destroy-fabric:
	@echo "=== Tearing down containerlab fabric ==="
	$(SCRIPTS)/destroy-fabric.sh

destroy-caas:
	@echo "=== Tearing down CaaS VMs ==="
	$(SCRIPTS)/destroy-caas.sh

gather-infra:
	@echo "=== Gathering infra diagnostics ==="
	$(SCRIPTS)/gather-infra.sh || true

gather-e2e:
	@echo "=== Gathering E2E diagnostics ==="
	$(SCRIPTS)/gather-e2e.sh || true

# ─── .PHONY ────────────────────────────────────────────────────────

.PHONY: setup-infra deploy-ocp deploy-osac deploy-fabric \
        setup-caas test-e2e \
        destroy-osac destroy-ocp destroy-fabric destroy-caas \
        gather-infra gather-e2e
