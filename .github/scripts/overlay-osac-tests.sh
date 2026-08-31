#!/usr/bin/env bash
# Replace ./tests/ with tests/ from an osac mono-repo checkout.
# Do not copy pyproject.toml or uv.lock — those stay with osac-test-infra so
# `uv sync --frozen` in the e2e Containerfile keeps working (osac's
# pyproject.toml is named osac-e2e and has no lockfile).
set -euo pipefail

SRC="${1:?usage: overlay-osac-tests.sh <osac-checkout-dir>}"

if [[ ! -d "${SRC}/tests/e2e" ]]; then
  echo "ERROR: ${SRC}/tests/e2e is missing — osac checkout does not have the migrated e2e layout" >&2
  exit 1
fi
if [[ ! -d "${SRC}/tests/core" ]]; then
  echo "ERROR: ${SRC}/tests/core is missing" >&2
  exit 1
fi
if [[ ! -f "${SRC}/tests/conftest.py" ]]; then
  echo "ERROR: ${SRC}/tests/conftest.py is missing" >&2
  exit 1
fi

rm -rf tests/
cp -r "${SRC}/tests" ./tests
