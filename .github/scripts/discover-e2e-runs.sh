#!/usr/bin/env bash
# Discover every repo/workflow currently calling into the reusable e2e
# workflows (this repo's own two, plus dynamic cross-repo discovery via code
# search), then list their completed runs since a cutoff time (OSAC-1684).
#
# Usage: discover-e2e-runs.sh <lookback-hours> <output-dir>
#
# Required env: GH_TOKEN (org-scoped -- needs to read Actions runs and search
# code across every repo this discovers, not just this one)
#
# Writes to <output-dir>:
#   runs.json    JSON array of {run_id, repo} for every completed run found
#   status.env   SKIPPED_TARGETS=N (targets whose run-listing call failed) and
#                DISCOVERY_FAILED=true|false (the cross-repo caller-discovery
#                call itself failed, distinct from a target's own run-listing
#                call failing), for the caller to `source`
set -euo pipefail

LOOKBACK_HOURS="${1:?Usage: discover-e2e-runs.sh <lookback-hours> <output-dir>}"
OUTPUT_DIR="${2:?Usage: discover-e2e-runs.sh <lookback-hours> <output-dir>}"
: "${GH_TOKEN:?GH_TOKEN is required}"
mkdir -p "${OUTPUT_DIR}"

SINCE=$(date -u -d "${LOOKBACK_HOURS} hours ago" +%Y-%m-%dT%H:%M:%SZ)
echo "Auditing runs completed since ${SINCE}..."

# This repo's own two reusable workflows are always in scope -- workflow_run
# (scan-e2e-logs.yml) only covers runs triggered directly here, so this audit
# is their cross-repo safety net too.
TARGETS=(
  "${GITHUB_REPOSITORY}:e2e-vmaas.yml"
  "${GITHUB_REPOSITORY}:e2e-vmaas-full-install.yml"
)

# Discover every OTHER repo currently calling into these reusable workflows,
# instead of relying on a manually maintained list (verified via a real run
# of this exact query that a static list goes stale fast: osac-aap,
# osac-operator, fulfillment-service, and a second caller inside
# osac-installer/nightly-build.yaml were all found this way, none of them in
# the original hand-written list). Local callers here use relative
# `uses: ./...` syntax so they don't match this search, which is why the
# baseline above is still needed. This dynamic discovery -- and the
# org-scoped token it requires -- becomes unnecessary once the planned
# monorepo migration lands.
#
# per_page=100 without pagination: comfortably covers current scale (5
# discovered callers org-wide); a real future-proofing gap if either the
# caller list or a single repo's completed-run count within the lookback
# window ever exceeds 100, deliberately deferred rather than fixed here.
echo "::group::Discover cross-repo callers"
DISCOVER_RESP="${OUTPUT_DIR}/discover.json"
HTTP_CODE=$(curl -sL -o "${DISCOVER_RESP}" -w '%{http_code}' \
  -H "Authorization: Bearer ${GH_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "${GITHUB_API_URL}/search/code?q=${GITHUB_REPOSITORY}%2F.github%2Fworkflows%2Fe2e-vmaas+org:osac-project&per_page=100")
# Distinct from a single target's own run-listing call failing below: this
# means every OTHER repo's runs were never even attempted this time, so it
# can't be inferred from SKIPPED_TARGETS staying 0 -- the caller must check
# this flag too, or a clean-looking audit could just be an incomplete one.
DISCOVERY_FAILED=false
if [[ "${HTTP_CODE}" != "200" ]]; then
  echo "::warning::Cross-repo caller discovery failed (HTTP ${HTTP_CODE}); auditing only this repo's own runs this time."
  DISCOVERY_FAILED=true
else
  while IFS= read -r TARGET; do
    TARGETS+=("${TARGET}")
  done < <(jq -r '.items[]? | "\(.repository.full_name):\(.path | split("/") | last)"' "${DISCOVER_RESP}" | sort -u)
fi
echo "Auditing ${#TARGETS[@]} target(s): ${TARGETS[*]}"
echo "::endgroup::"

RUNS="[]"
SKIPPED_TARGETS=0
for TARGET in "${TARGETS[@]}"; do
  REPO="${TARGET%%:*}"
  WORKFLOW="${TARGET#*:}"
  RESP_FILE="${OUTPUT_DIR}/runs-resp.json"
  # No `created=>` filter: that compares against a run's *start* time, so a
  # long-running run started before the window but finished inside it would
  # never match and would go permanently unaudited. Runs are returned newest
  # (by created_at) first, so the plain per_page=100 fetch below still
  # comfortably includes such runs -- then filtered locally by `updated_at`
  # (GitHub's closest proxy for completion time) against the actual window.
  HTTP_CODE=$(curl -sL -o "${RESP_FILE}" -w '%{http_code}' \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${GITHUB_API_URL}/repos/${REPO}/actions/workflows/${WORKFLOW}/runs?status=completed&per_page=100")
  if [[ "${HTTP_CODE}" != "200" ]]; then
    echo "::warning::Could not list runs for ${TARGET} (HTTP ${HTTP_CODE}), skipping."
    SKIPPED_TARGETS=$((SKIPPED_TARGETS + 1))
    continue
  fi
  IDS=$(jq --arg repo "${REPO}" --arg since "${SINCE}" \
    '[.workflow_runs[]? | select(.updated_at >= $since) | {run_id: (.id | tostring), repo: $repo}]' "${RESP_FILE}")
  RUNS=$(jq -cn --argjson a "${RUNS}" --argjson b "${IDS}" '$a + $b')
done

echo "Found $(echo "${RUNS}" | jq 'length') run(s) to audit across ${#TARGETS[@]} target(s)."
echo "${RUNS}" > "${OUTPUT_DIR}/runs.json"
{
  echo "SKIPPED_TARGETS=${SKIPPED_TARGETS}"
  echo "DISCOVERY_FAILED=${DISCOVERY_FAILED}"
} > "${OUTPUT_DIR}/status.env"
