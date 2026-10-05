#!/usr/bin/env bash
# Resolve the e2e test-suite from an optional explicit input and PR tier labels.
#
# Usage:
#   resolve-e2e-suite.sh PLATFORM DEFAULT_SUITE [EXPLICIT_SUITE]
#
# Env (optional):
#   EVENT_NAME     — github.event_name (default: pull_request)
#   PR_NUMBER      — PR number (required for workflow_dispatch label lookup)
#   PR_LABELS      — comma-separated label names from the pull_request event
#   GH_TOKEN       — token for API label lookup when PR_LABELS is empty
#   GITHUB_REPOSITORY — owner/repo for API lookup
#
# Prints the suite path to stdout (e.g. vmaas/regression). Priority:
#   1) e2e-serial label → PLATFORM/serial
#   2) e2e-regression label → PLATFORM/regression
#   3) non-empty EXPLICIT_SUITE (workflow_dispatch input / its default)
#   4) DEFAULT_SUITE
set -euo pipefail

PLATFORM=${1:?platform required}
DEFAULT_SUITE=${2:?default suite required}
EXPLICIT_SUITE=${3:-}
EVENT_NAME=${EVENT_NAME:-pull_request}
PR_NUMBER=${PR_NUMBER:-}
PR_LABELS=${PR_LABELS:-}
GITHUB_REPOSITORY=${GITHUB_REPOSITORY:-}

if [[ ! "${PLATFORM}" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "resolve-e2e-suite: invalid platform: ${PLATFORM}" >&2
  exit 1
fi

labels=""
if [[ -n "${PR_LABELS}" ]]; then
  labels=$(printf '%s' "${PR_LABELS}" | tr ',' '\n')
elif [[ -n "${PR_NUMBER}" && -n "${GITHUB_REPOSITORY}" ]]; then
  command -v gh >/dev/null 2>&1 || {
    echo "resolve-e2e-suite: gh is required to load PR labels" >&2
    exit 1
  }
  labels=$(gh api "repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/labels" \
    --jq '.[].name' 2>/dev/null || true)
fi

if printf '%s\n' "${labels}" | grep -Fxq e2e-serial; then
  printf '%s/serial\n' "${PLATFORM}"
  exit 0
fi
if printf '%s\n' "${labels}" | grep -Fxq e2e-regression; then
  printf '%s/regression\n' "${PLATFORM}"
  exit 0
fi

if [[ -n "${EXPLICIT_SUITE}" ]]; then
  printf '%s\n' "${EXPLICIT_SUITE}"
  exit 0
fi

printf '%s\n' "${DEFAULT_SUITE}"
