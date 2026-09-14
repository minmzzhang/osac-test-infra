#!/usr/bin/env bash
# Unit tests for native gate conclusion helpers in e2e-gates-lib.sh.
# shellcheck disable=SC2034 # CHECK_RUNS_JSON is read by sourced helpers
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=e2e-gates-lib.sh
source "${SCRIPT_DIR}/e2e-gates-lib.sh"

pass=0
fail=0

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    echo "PASS: ${name}"
    pass=$((pass + 1))
  else
    echo "FAIL: ${name} (expected=${expected} actual=${actual})"
    fail=$((fail + 1))
  fi
}

assert_rc() {
  local name="$1" expected_rc="$2"
  shift 2
  set +e
  "$@" >/dev/null 2>&1
  local rc=$?
  set -e
  assert_eq "${name}" "${expected_rc}" "${rc}"
}

orphan='{
  "name":"e2e-vmaas-gate",
  "status":"in_progress",
  "conclusion":null,
  "details_url":"https://github.com/osac-project/osac/runs/1",
  "started_at":"2026-01-01T00:00:00Z",
  "external_id":"osac-invalidate-e2e-gate:e2e-vmaas-gate"
}'
native_fail='{
  "name":"e2e-vmaas-gate",
  "status":"completed",
  "conclusion":"failure",
  "details_url":"https://github.com/osac-project/osac/actions/runs/9/job/9",
  "started_at":"2026-01-01T00:01:00Z"
}'
native_ok='{
  "name":"e2e-vmaas-gate",
  "status":"completed",
  "conclusion":"success",
  "details_url":"https://github.com/osac-project/osac/actions/runs/9/job/9",
  "started_at":"2026-01-01T00:01:00Z"
}'
native_pending='{
  "name":"e2e-vmaas-gate",
  "status":"in_progress",
  "conclusion":null,
  "details_url":"https://github.com/osac-project/osac/actions/runs/9/job/9",
  "started_at":"2026-01-01T00:01:00Z"
}'

CHECK_RUNS_JSON="[${orphan}]"
assert_eq "orphan only is missing native" "missing" "$(native_gate_job_conclusion e2e-vmaas-gate)"

CHECK_RUNS_JSON="[${orphan},${native_fail}]"
assert_eq "native failure is latest job" "failure" "$(native_gate_job_conclusion e2e-vmaas-gate)"
assert_rc "failure is mirrorable" 0 native_gate_conclusion_is_mirrorable failure
assert_rc "native failure is not success" 1 native_gate_job_success e2e-vmaas-gate

CHECK_RUNS_JSON="[${orphan},${native_ok}]"
assert_eq "native success is latest job" "success" "$(native_gate_job_conclusion e2e-vmaas-gate)"
assert_rc "native success helper" 0 native_gate_job_success e2e-vmaas-gate

CHECK_RUNS_JSON="[${orphan},${native_pending}]"
assert_eq "in_progress native job is pending" "pending" "$(native_gate_job_conclusion e2e-vmaas-gate)"
assert_rc "pending is not mirrorable" 1 native_gate_conclusion_is_mirrorable pending
assert_rc "missing is not mirrorable" 1 native_gate_conclusion_is_mirrorable missing
assert_rc "cancelled is mirrorable" 0 native_gate_conclusion_is_mirrorable cancelled
assert_rc "skipped is mirrorable" 0 native_gate_conclusion_is_mirrorable skipped

echo "---"
echo "pass=${pass} fail=${fail}"
if [[ "${fail}" -ne 0 ]]; then
  exit 1
fi
