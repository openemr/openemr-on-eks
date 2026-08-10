#!/usr/bin/env bash
# Run Floci-backed integration suites (BATS smoke + pytest -m floci).
# Requires a live Floci endpoint via AWS_ENDPOINT_URL (CI service or local compose).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FLOCI_DIR="${PROJECT_ROOT}/tests/floci"

# shellcheck source=tests/floci/env.sh
# shellcheck disable=SC1091
source "${FLOCI_DIR}/env.sh"

if [ -z "${AWS_ENDPOINT_URL:-}" ]; then
  echo "ERROR: AWS_ENDPOINT_URL is required for Floci integration tests" >&2
  exit 1
fi

echo "=== Waiting for Floci ==="
"${FLOCI_DIR}/wait.sh" "${AWS_ENDPOINT_URL}"

echo "=== Seeding Floci ==="
# shellcheck disable=SC1091
source "${FLOCI_DIR}/seed.sh"

FAILED=0

echo "=== BATS Floci smoke ==="
if command -v bats >/dev/null 2>&1; then
  if ! (cd "${PROJECT_ROOT}" && bats tests/bats/floci-smoke.bats); then
    FAILED=1
  fi
else
  echo "ERROR: bats is required for Floci integration" >&2
  FAILED=1
fi

run_pytest_floci() {
  local label="$1"
  shift
  echo "=== ${label} ==="
  if ! "$@"; then
    FAILED=1
  fi
}

# Prefer already-installed project venvs from install-python-dev.sh when present.
if [ -x "${PROJECT_ROOT}/warp/.venv/bin/pytest" ]; then
  run_pytest_floci "Warp Floci pytest" \
    env PYTHONPATH="${PROJECT_ROOT}/warp" \
    "${PROJECT_ROOT}/warp/.venv/bin/pytest" -m floci "${PROJECT_ROOT}/warp/tests/test_floci_s3.py" -v
elif command -v pytest >/dev/null 2>&1; then
  run_pytest_floci "Warp Floci pytest" \
    env PYTHONPATH="${PROJECT_ROOT}/warp" pytest -m floci "${PROJECT_ROOT}/warp/tests/test_floci_s3.py" -v
else
  echo "WARNING: skipping Warp Floci pytest (no venv/pytest)" >&2
fi

if [ -x "${PROJECT_ROOT}/tools/credential-rotation/.venv/bin/pytest" ]; then
  run_pytest_floci "Credential-rotation Floci pytest" \
    env PYTHONPATH="${PROJECT_ROOT}/tools/credential-rotation/src" \
    "${PROJECT_ROOT}/tools/credential-rotation/.venv/bin/pytest" -m floci \
    "${PROJECT_ROOT}/tools/credential-rotation/tests/test_floci_secrets.py" -v
elif command -v pytest >/dev/null 2>&1; then
  run_pytest_floci "Credential-rotation Floci pytest" \
    env PYTHONPATH="${PROJECT_ROOT}/tools/credential-rotation/src" \
    pytest -m floci "${PROJECT_ROOT}/tools/credential-rotation/tests/test_floci_secrets.py" -v
else
  echo "WARNING: skipping credential-rotation Floci pytest (no venv/pytest)" >&2
fi

if [ -x "${PROJECT_ROOT}/scripts/.venv-openemr-dr/bin/python" ]; then
  run_pytest_floci "openemr_dr Floci pytest" \
    env PYTHONPATH="${PROJECT_ROOT}/scripts" \
    "${PROJECT_ROOT}/scripts/.venv-openemr-dr/bin/python" -m pytest -m floci \
    "${PROJECT_ROOT}/scripts/openemr_dr/tests/test_floci_aws.py" -v
elif command -v python3 >/dev/null 2>&1; then
  run_pytest_floci "openemr_dr Floci pytest" \
    env PYTHONPATH="${PROJECT_ROOT}/scripts" \
    python3 -m pytest -m floci "${PROJECT_ROOT}/scripts/openemr_dr/tests/test_floci_aws.py" -v
else
  echo "WARNING: skipping openemr_dr Floci pytest (no python)" >&2
fi

if [ "${FAILED}" -ne 0 ]; then
  echo "Floci integration suites FAILED" >&2
  exit 1
fi

echo "Floci integration suites PASSED"
