#!/usr/bin/env bash
# Unit tests for check-e2e-readiness.sh decision helpers (OSAC-3370).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./check-e2e-readiness.sh
CHECK_E2E_READINESS_LIB_ONLY=1 source "${SCRIPT_DIR}/check-e2e-readiness.sh"

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

LABELS_E2E_READY='[{"name":"e2e-ready"},{"name":"bug"}]'
LABELS_LGTM='[{"name":"lgtm"},{"name":"bug"}]'
LABELS_BOTH='[{"name":"lgtm"},{"name":"e2e-ready"}]'
LABELS_WITHOUT='[{"name":"bug"}]'
LABELS_EMPTY='[]'

HEAD_SHA='head-commit'

REVIEWS_BOT_WITH_HUMAN_CR='[
  {"id":1,"submitted_at":"2026-01-01T00:00:00Z","state":"CHANGES_REQUESTED","commit_id":"old-commit","author_association":"MEMBER","user":{"login":"alice","type":"User"}},
  {"id":2,"submitted_at":"2026-01-02T00:00:00Z","state":"APPROVED","commit_id":"head-commit","author_association":"NONE","user":{"login":"coderabbitai[bot]","type":"Bot"}}
]'

REVIEWS_BOT_ONLY='[
  {"id":1,"submitted_at":"2026-01-02T00:00:00Z","state":"APPROVED","commit_id":"head-commit","author_association":"NONE","user":{"login":"coderabbitai[bot]","type":"Bot"}}
]'

REVIEWS_BOT_THEN_DISMISS='[
  {"id":1,"submitted_at":"2026-01-02T00:00:00Z","state":"APPROVED","commit_id":"head-commit","author_association":"NONE","user":{"login":"coderabbitai[bot]","type":"Bot"}},
  {"id":2,"submitted_at":"2026-01-02T01:00:00Z","state":"DISMISSED","commit_id":"head-commit","author_association":"NONE","user":{"login":"coderabbitai[bot]","type":"Bot"}}
]'

REVIEWS_HUMAN_APPROVED='[
  {"id":1,"submitted_at":"2026-01-02T00:00:00Z","state":"APPROVED","commit_id":"head-commit","author_association":"MEMBER","user":{"login":"alice","type":"User"}}
]'

REVIEWS_OTHER_BOT_APPROVED='[
  {"id":1,"submitted_at":"2026-01-02T00:00:00Z","state":"APPROVED","commit_id":"head-commit","author_association":"NONE","user":{"login":"dependabot[bot]","type":"Bot"}}
]'

REVIEWS_COMMENT_AFTER_CR_BOT_APPROVE='[
  {"id":1,"submitted_at":"2026-01-01T00:00:00Z","state":"CHANGES_REQUESTED","commit_id":"old-commit","author_association":"MEMBER","user":{"login":"alice","type":"User"}},
  {"id":2,"submitted_at":"2026-01-02T00:00:00Z","state":"COMMENTED","commit_id":"head-commit","author_association":"MEMBER","user":{"login":"alice","type":"User"}},
  {"id":3,"submitted_at":"2026-01-02T00:00:01Z","state":"APPROVED","commit_id":"head-commit","author_association":"NONE","user":{"login":"coderabbitai[bot]","type":"Bot"}}
]'

REVIEWS_APPROVED_OLD='[
  {"id":1,"submitted_at":"2026-01-01T00:00:00Z","state":"APPROVED","commit_id":"old-commit","author_association":"NONE","user":{"login":"coderabbitai[bot]","type":"Bot"}}
]'
REVIEWS_NONE='[]'

# Same submitted_at: higher review id must win (tie-breaker).
REVIEWS_HUMAN_SAME_SECOND_CR_WINS='[
  {"id":1,"submitted_at":"2026-01-02T00:00:00Z","state":"APPROVED","commit_id":"head-commit","author_association":"MEMBER","user":{"login":"alice","type":"User"}},
  {"id":2,"submitted_at":"2026-01-02T00:00:00Z","state":"CHANGES_REQUESTED","commit_id":"head-commit","author_association":"MEMBER","user":{"login":"alice","type":"User"}},
  {"id":3,"submitted_at":"2026-01-02T00:00:00Z","state":"APPROVED","commit_id":"head-commit","author_association":"NONE","user":{"login":"coderabbitai[bot]","type":"Bot"}}
]'
REVIEWS_BOT_SAME_SECOND_DISMISS_WINS='[
  {"id":1,"submitted_at":"2026-01-02T00:00:00Z","state":"APPROVED","commit_id":"head-commit","author_association":"NONE","user":{"login":"coderabbitai[bot]","type":"Bot"}},
  {"id":2,"submitted_at":"2026-01-02T00:00:00Z","state":"DISMISSED","commit_id":"head-commit","author_association":"NONE","user":{"login":"coderabbitai[bot]","type":"Bot"}}
]'
REVIEWS_BOT_SAME_SECOND_APPROVE_WINS='[
  {"id":1,"submitted_at":"2026-01-02T00:00:00Z","state":"DISMISSED","commit_id":"head-commit","author_association":"NONE","user":{"login":"coderabbitai[bot]","type":"Bot"}},
  {"id":2,"submitted_at":"2026-01-02T00:00:00Z","state":"APPROVED","commit_id":"head-commit","author_association":"NONE","user":{"login":"coderabbitai[bot]","type":"Bot"}}
]'

EVENTS_LABELED='[
  {"event":"labeled","created_at":"2026-01-01T00:00:00Z","label":{"name":"bug"}},
  {"event":"labeled","created_at":"2026-01-02T12:00:00Z","label":{"name":"e2e-ready"}},
  {"event":"labeled","created_at":"2026-01-02T13:00:00Z","label":{"name":"lgtm"}},
  {"event":"unlabeled","created_at":"2026-01-02T11:00:00Z","label":{"name":"e2e-ready"}}
]'

assert_rc "labels_have_e2e_ready yes" 0 labels_have_e2e_ready "${LABELS_E2E_READY}"
assert_rc "labels_have_e2e_ready no" 1 labels_have_e2e_ready "${LABELS_WITHOUT}"
assert_rc "labels_have_lgtm yes" 0 labels_have_lgtm "${LABELS_LGTM}"
assert_rc "labels_have_lgtm no" 1 labels_have_lgtm "${LABELS_WITHOUT}"
assert_rc "labels_have_e2e_ready empty" 1 labels_have_e2e_ready "${LABELS_EMPTY}"

assert_eq "latest e2e-ready labeled_at" "2026-01-02T12:00:00Z" "$(latest_e2e_ready_labeled_at "${EVENTS_LABELED}")"
assert_eq "latest lgtm labeled_at" "2026-01-02T13:00:00Z" "$(latest_label_labeled_at "${EVENTS_LABELED}" "lgtm")"
assert_rc "label fresh after head" 0 label_is_fresh "2026-01-02T12:00:00Z" "2026-01-02T11:00:00Z"
assert_rc "label stale before head" 1 label_is_fresh "2026-01-02T10:00:00Z" "2026-01-02T11:00:00Z"
assert_rc "label fresh equal head" 0 label_is_fresh "2026-01-02T11:00:00Z" "2026-01-02T11:00:00Z"
assert_rc "label missing labeled_at" 1 label_is_fresh "" "2026-01-02T11:00:00Z"
assert_rc "label missing head_seen_at" 1 label_is_fresh "2026-01-02T12:00:00Z" ""
assert_rc "label both timestamps missing" 1 label_is_fresh "" ""

assert_rc "human_has_changes_requested yes" 0 human_has_changes_requested "${REVIEWS_BOT_WITH_HUMAN_CR}"
assert_rc "human_has_changes_requested no (bot only)" 1 human_has_changes_requested "${REVIEWS_BOT_ONLY}"
assert_rc "human_has_changes_requested yes (comment after CR)" 0 human_has_changes_requested "${REVIEWS_COMMENT_AFTER_CR_BOT_APPROVE}"

assert_rc "coderabbit empty head_sha" 1 coderabbit_approves_head "${REVIEWS_BOT_ONLY}" ""
assert_rc "coderabbit approves bot only" 0 coderabbit_approves_head "${REVIEWS_BOT_ONLY}" "${HEAD_SHA}"
assert_rc "coderabbit blocked by human CR" 1 coderabbit_approves_head "${REVIEWS_BOT_WITH_HUMAN_CR}" "${HEAD_SHA}"
assert_rc "coderabbit comment after CR still blocked" 1 coderabbit_approves_head "${REVIEWS_COMMENT_AFTER_CR_BOT_APPROVE}" "${HEAD_SHA}"
assert_rc "coderabbit dismissed after approve" 1 coderabbit_approves_head "${REVIEWS_BOT_THEN_DISMISS}" "${HEAD_SHA}"
assert_rc "coderabbit old sha" 1 coderabbit_approves_head "${REVIEWS_APPROVED_OLD}" "${HEAD_SHA}"
assert_rc "coderabbit none" 1 coderabbit_approves_head "${REVIEWS_NONE}" "${HEAD_SHA}"
assert_rc "coderabbit short sha" 1 coderabbit_approves_head "${REVIEWS_BOT_ONLY}" "head"
assert_rc "human approve does not unlock" 1 coderabbit_approves_head "${REVIEWS_HUMAN_APPROVED}" "${HEAD_SHA}"
assert_rc "other bot does not unlock" 1 coderabbit_approves_head "${REVIEWS_OTHER_BOT_APPROVED}" "${HEAD_SHA}"
assert_rc "human same-second higher id CR blocks" 0 human_has_changes_requested "${REVIEWS_HUMAN_SAME_SECOND_CR_WINS}"
assert_rc "coderabbit blocked by same-second human CR" 1 coderabbit_approves_head "${REVIEWS_HUMAN_SAME_SECOND_CR_WINS}" "${HEAD_SHA}"
assert_rc "coderabbit same-second higher id dismiss" 1 coderabbit_approves_head "${REVIEWS_BOT_SAME_SECOND_DISMISS_WINS}" "${HEAD_SHA}"
assert_rc "coderabbit same-second higher id approve" 0 coderabbit_approves_head "${REVIEWS_BOT_SAME_SECOND_APPROVE_WINS}" "${HEAD_SHA}"

# Fresh-label cases pass trust_*=1 explicitly (defaults are fail-closed 0).
assert_rc "decide lgtm wins" 0 decide_e2e_readiness "${LABELS_LGTM}" "${REVIEWS_NONE}" "${HEAD_SHA}" 1 1
assert_eq "decide lgtm wins reason" \
  "allowed: lgtm label present (fresh for head)" \
  "$(decide_e2e_readiness "${LABELS_LGTM}" "${REVIEWS_NONE}" "${HEAD_SHA}" 1 1)"
assert_rc "decide e2e-ready wins" 0 decide_e2e_readiness "${LABELS_E2E_READY}" "${REVIEWS_NONE}" "${HEAD_SHA}" 1 1
assert_eq "decide e2e-ready wins reason" \
  "allowed: e2e-ready label present (fresh for head)" \
  "$(decide_e2e_readiness "${LABELS_E2E_READY}" "${REVIEWS_NONE}" "${HEAD_SHA}" 1 1)"
assert_rc "decide both labels" 0 decide_e2e_readiness "${LABELS_BOTH}" "${REVIEWS_NONE}" "${HEAD_SHA}" 1 1
assert_eq "decide both labels prefers lgtm" \
  "allowed: lgtm label present (fresh for head)" \
  "$(decide_e2e_readiness "${LABELS_BOTH}" "${REVIEWS_NONE}" "${HEAD_SHA}" 1 1)"
assert_rc "decide e2e-ready overrides human CR" 0 decide_e2e_readiness "${LABELS_E2E_READY}" "${REVIEWS_BOT_WITH_HUMAN_CR}" "${HEAD_SHA}" 1 1
assert_eq "decide e2e-ready overrides human CR reason" \
  "allowed: e2e-ready label present (fresh for head)" \
  "$(decide_e2e_readiness "${LABELS_E2E_READY}" "${REVIEWS_BOT_WITH_HUMAN_CR}" "${HEAD_SHA}" 1 1)"
assert_rc "decide lgtm overrides human CR" 0 decide_e2e_readiness "${LABELS_LGTM}" "${REVIEWS_BOT_WITH_HUMAN_CR}" "${HEAD_SHA}" 1 1
assert_eq "decide lgtm overrides human CR reason" \
  "allowed: lgtm label present (fresh for head)" \
  "$(decide_e2e_readiness "${LABELS_LGTM}" "${REVIEWS_BOT_WITH_HUMAN_CR}" "${HEAD_SHA}" 1 1)"
assert_rc "decide labels ignored when trust defaults" 1 decide_e2e_readiness "${LABELS_LGTM}" "${REVIEWS_NONE}" "${HEAD_SHA}"
assert_rc "decide stale e2e-ready ignored" 1 decide_e2e_readiness "${LABELS_E2E_READY}" "${REVIEWS_NONE}" "${HEAD_SHA}" 0 0
assert_rc "decide stale lgtm ignored" 1 decide_e2e_readiness "${LABELS_LGTM}" "${REVIEWS_NONE}" "${HEAD_SHA}" 0 0
assert_eq "decide fresh e2e-ready with stale lgtm" \
  "allowed: e2e-ready label present (fresh for head)" \
  "$(decide_e2e_readiness "${LABELS_BOTH}" "${REVIEWS_NONE}" "${HEAD_SHA}" 1 0)"
assert_eq "decide fresh lgtm with stale e2e-ready" \
  "allowed: lgtm label present (fresh for head)" \
  "$(decide_e2e_readiness "${LABELS_BOTH}" "${REVIEWS_NONE}" "${HEAD_SHA}" 0 1)"
assert_rc "decide stale labels still allow CR" 0 decide_e2e_readiness "${LABELS_E2E_READY}" "${REVIEWS_BOT_ONLY}" "${HEAD_SHA}" 0 0
assert_eq "decide stale labels still allow CR reason" \
  "allowed: APPROVED review on head from coderabbitai[bot]" \
  "$(decide_e2e_readiness "${LABELS_E2E_READY}" "${REVIEWS_BOT_ONLY}" "${HEAD_SHA}" 0 0)"
assert_rc "decide CR alone wins" 0 decide_e2e_readiness "${LABELS_WITHOUT}" "${REVIEWS_BOT_ONLY}" "${HEAD_SHA}"
assert_eq "decide CR alone wins reason" \
  "allowed: APPROVED review on head from coderabbitai[bot]" \
  "$(decide_e2e_readiness "${LABELS_WITHOUT}" "${REVIEWS_BOT_ONLY}" "${HEAD_SHA}")"
assert_rc "decide CR blocked by human CR" 1 decide_e2e_readiness "${LABELS_WITHOUT}" "${REVIEWS_BOT_WITH_HUMAN_CR}" "${HEAD_SHA}"
assert_rc "decide denied human approve" 1 decide_e2e_readiness "${LABELS_WITHOUT}" "${REVIEWS_HUMAN_APPROVED}" "${HEAD_SHA}"
assert_rc "decide denied old CR approve" 1 decide_e2e_readiness "${LABELS_WITHOUT}" "${REVIEWS_APPROVED_OLD}" "${HEAD_SHA}"
assert_rc "decide denied other bot" 1 decide_e2e_readiness "${LABELS_WITHOUT}" "${REVIEWS_OTHER_BOT_APPROVED}" "${HEAD_SHA}"

echo ""
echo "Results: ${pass} passed, ${fail} failed"
if (( fail > 0 )); then
  exit 1
fi
