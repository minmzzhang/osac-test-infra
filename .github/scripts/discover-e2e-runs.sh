#!/usr/bin/env bash
# Discover every repo/workflow currently calling into the reusable e2e
# workflows (this repo's own two, plus dynamic cross-repo discovery via code
# search), then list their completed runs created since a cutoff time
# (OSAC-1684). The GitHub workflow-runs API only filters by `created` (start
# time), not completion/`updated_at`, so the lookback window is start-time
# based -- see the per-target listing comment below.
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
# workflow_dispatch's lookback-hours input is user-supplied and unvalidated
# at that point -- 0, a negative number, or non-numeric text would all
# produce a bad or empty `date` result below, silently auditing an
# incorrect (possibly empty) window while still reporting a "successful"
# run. Fail loudly on a malformed value instead of letting it flow through.
if ! [[ "${LOOKBACK_HOURS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "lookback-hours must be a positive integer, got: ${LOOKBACK_HOURS}" >&2
  exit 2
fi
# Upper-bounded too, tied to the per_page=100-without-pagination limitation
# already called out below: an arbitrarily large manual re-audit window
# makes that deferred gap more likely to actually bite (created= filter
# returns more than 100 in-window runs per target). 168h (1 week) is a
# generous ceiling for a manual catch-up re-scan, not a guarantee that any
# single target stays under 100 in-window runs -- just a sanity bound
# against a fat-fingered input. Targets over that are skipped (and
# counted) rather than silently under-audited.
if (( LOOKBACK_HOURS > 168 )); then
  echo "lookback-hours must be <= 168 (1 week) -- see per_page=100 pagination note below" >&2
  exit 2
fi
mkdir -p "${OUTPUT_DIR}"

# created= is start-time based (GitHub has no updated_at filter), so a run
# started before the window and finished inside it is invisible to us. The
# default 27h lookback on a 24h schedule gives a 3h overlap -- enough to catch
# runs up to ~3h long that started in the previous window. Jobs longer than
# that are theoretically missed, but our longest E2E suites run ~2h.
SINCE=$(date -u -d "${LOOKBACK_HOURS} hours ago" +%Y-%m-%dT%H:%M:%SZ)
echo "Auditing completed runs created since ${SINCE}..."

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
# discovered callers org-wide). Actually paginating is still deferred, but
# exceeding 100 (or an incomplete search due to a server-side timeout) is
# now at least detected and treated as DISCOVERY_FAILED=true below, rather
# than silently returning a truncated/partial first page as if it were
# the complete result.
echo "::group::Discover cross-repo callers"
DISCOVER_RESP="${OUTPUT_DIR}/discover.json"
# `if ! VAR=$(...)`, not a plain assignment: a curl *transport* failure
# (DNS, connection refused/reset, TLS) isn't exempt from `set -e` just
# because we're deliberately not using --fail (that only covers curl not
# treating HTTP 4xx/5xx as failure) - an unguarded assignment would still
# trip errexit and kill the script before status.env ever gets written.
if ! HTTP_CODE=$(curl -sL -o "${DISCOVER_RESP}" -w '%{http_code}' \
  --connect-timeout 10 --max-time 30 \
  -H "Authorization: Bearer ${GH_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "${GITHUB_API_URL}/search/code?q=${GITHUB_REPOSITORY}%2F.github%2Fworkflows%2Fe2e-vmaas+org:osac-project+path:.github/workflows&per_page=100"); then
  HTTP_CODE="curl-transport-error"
fi
# Distinct from a single target's own run-listing call failing below: this
# means every OTHER repo's runs were never even attempted this time, so it
# can't be inferred from SKIPPED_TARGETS staying 0 -- the caller must check
# this flag too, or a clean-looking audit could just be an incomplete one.
DISCOVERY_FAILED=false
# A 200 doesn't guarantee a *complete* result, on top of not guaranteeing
# the expected *shape*: GitHub's code-search endpoint can return
# incomplete_results=true (a documented behavior on internal search
# timeout) with an otherwise well-formed, valid-array `.items` -- the shape
# check alone wouldn't catch that. total_count > 100 is the pre-existing,
# deliberately-deferred non-pagination gap made concrete: rather than
# silently returning only the first page, treat exceeding it as a failure
# too, so it's visible instead of quietly dropping callers.
if [[ "${HTTP_CODE}" != "200" ]] \
  || ! jq -e '.items | type == "array"' "${DISCOVER_RESP}" >/dev/null 2>&1 \
  || ! jq -e '.incomplete_results == false' "${DISCOVER_RESP}" >/dev/null 2>&1 \
  || ! jq -e '(.total_count | type) == "number" and .total_count >= 0 and .total_count <= 100' "${DISCOVER_RESP}" >/dev/null 2>&1; then
  echo "::warning::Cross-repo caller discovery failed (HTTP ${HTTP_CODE}, unexpected response shape, incomplete search results, or more than 100 matches); auditing only this repo's own runs this time."
  DISCOVERY_FAILED=true
elif ! jq -e 'all(.items[]?; type == "object" and (.repository.full_name | type) == "string" and (.path | type) == "string")' "${DISCOVER_RESP}" >/dev/null 2>&1; then
  # Deliberately all-or-nothing, not a per-item select() drop: silently
  # dropping just the one malformed item would leave DISCOVERY_FAILED
  # false while the target list is quietly incomplete -- indistinguishable
  # from "found every caller, all of them were valid" to everything
  # downstream. One bad item makes the whole discovery result untrusted.
  echo "::warning::Discovery response contains a malformed item; auditing only this repo's own runs this time."
  DISCOVERY_FAILED=true
else
  # Extracted to a file with its own explicitly-checked exit status, not
  # piped straight into the while loop via process substitution: a jq
  # runtime error partway through the stream wouldn't fail the while loop
  # at all under set -e -- process substitution's exit status isn't
  # observed by the surrounding shell. The all() check above already
  # guarantees every item is well-formed by this point.
  DISCOVER_TARGETS_FILE="${OUTPUT_DIR}/discover-targets.txt"
  if ! jq -r '.items[]? | "\(.repository.full_name):\(.path | split("/") | last)"' "${DISCOVER_RESP}" \
    | sort -u > "${DISCOVER_TARGETS_FILE}"; then
    echo "::warning::Failed to extract discovery targets from search response; auditing only this repo's own runs this time."
    DISCOVERY_FAILED=true
  else
    while IFS= read -r TARGET; do
      TARGETS+=("${TARGET}")
    done < "${DISCOVER_TARGETS_FILE}"
  fi
fi
echo "Auditing ${#TARGETS[@]} target(s): ${TARGETS[*]}"
echo "::endgroup::"

RUNS="[]"
SKIPPED_TARGETS=0
for TARGET in "${TARGETS[@]}"; do
  REPO="${TARGET%%:*}"
  WORKFLOW="${TARGET#*:}"
  RESP_FILE="${OUTPUT_DIR}/runs-resp.json"
  # Filter by created at the API first so total_count is "completed runs
  # started in the lookback window", not lifetime history. Without that,
  # a total_count<=100 guard rejects every busy caller (hundreds of
  # historical runs) before any local window filter can run -- which is
  # what made the daily audit skip fulfillment-service/osac-aap/
  # osac-installer/osac-operator entirely.
  #
  # GitHub only exposes a `created` filter here, not `updated_at`, so the
  # window is start-time based. A run that started before SINCE and
  # finished inside the window can be missed; with a daily 27h lookback
  # that only matters for jobs longer than the 3h overlap, which we accept
  # over the previous "skip the whole target" failure mode. Pagination is
  # still deferred -- if a target ever exceeds 100 in-window runs, skip
  # it loudly rather than silently truncating.
  # -G + --data-urlencode: `created=>=...` must be form-encoded (`>=` /
  # `:` in the timestamp); baking it into the URL path is easy to get wrong.
  if ! HTTP_CODE=$(curl -sL -o "${RESP_FILE}" -w '%{http_code}' \
    --connect-timeout 10 --max-time 30 \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -G "${GITHUB_API_URL}/repos/${REPO}/actions/workflows/${WORKFLOW}/runs" \
    --data-urlencode "status=completed" \
    --data-urlencode "per_page=100" \
    --data-urlencode "created=>=${SINCE}"); then
    HTTP_CODE="curl-transport-error"
  fi
  # Same "200 doesn't guarantee shape" reasoning as the discovery call above
  # -- an unexpected/missing .workflow_runs would otherwise become `[]` via
  # `?`, silently counting a target that actually has runs as cleanly
  # audited instead of skipped. total_count > 100 is now meaningful: the
  # created= filter makes it an in-window count, so exceeding per_page
  # without pagination is a real coverage gap for this target.
  # All-or-nothing on shape/type here too, same reasoning as the discovery
  # response: a select()-style per-item drop would leave one malformed run
  # silently missing from RUNS while this target still counts as cleanly
  # audited (not skipped) -- indistinguishable from "every run was valid."
  if [[ "${HTTP_CODE}" != "200" ]] \
    || ! jq -e '.workflow_runs | type == "array"' "${RESP_FILE}" >/dev/null 2>&1 \
    || ! jq -e '(.total_count | type) == "number" and .total_count >= 0 and .total_count <= 100' "${RESP_FILE}" >/dev/null 2>&1 \
    || ! jq -e 'all(.workflow_runs[]?; type == "object" and (.id | type) == "number")' "${RESP_FILE}" >/dev/null 2>&1; then
    echo "::warning::Could not list runs for ${TARGET} (HTTP ${HTTP_CODE}, unexpected response shape, malformed run item, or more than 100 in-window runs), skipping."
    SKIPPED_TARGETS=$((SKIPPED_TARGETS + 1))
    continue
  fi
  IDS=$(jq --arg repo "${REPO}" \
    '[.workflow_runs[]? | {run_id: (.id | tostring), repo: $repo}]' "${RESP_FILE}")
  RUNS=$(jq -cn --argjson a "${RUNS}" --argjson b "${IDS}" '$a + $b')
done

echo "Found $(echo "${RUNS}" | jq 'length') run(s) to audit across ${#TARGETS[@]} target(s)."
echo "${RUNS}" > "${OUTPUT_DIR}/runs.json"
{
  echo "SKIPPED_TARGETS=${SKIPPED_TARGETS}"
  echo "DISCOVERY_FAILED=${DISCOVERY_FAILED}"
} > "${OUTPUT_DIR}/status.env"
