#!/usr/bin/env bash
# Unified Python package CI runner (install pinned deps + project-specific checks).
#
# Usage:
#   ./scripts/ci/run-python-ci.sh openemr_dr
#   ./scripts/ci/run-python-ci.sh warp
#   ./scripts/ci/run-python-ci.sh credential_rotation
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT="${1:-}"

if [[ -z "${PROJECT}" ]]; then
  echo "Usage: $0 {openemr_dr|warp|credential_rotation}" >&2
  exit 1
fi

case "${PROJECT}" in
  openemr_dr)
    "${SCRIPTS_DIR}/validate-python-requirements.sh" openemr_dr
    "${SCRIPTS_DIR}/install-python-dev.sh" openemr_dr
    # shellcheck disable=SC1091
    source "${SCRIPTS_DIR}/.venv-openemr-dr/bin/activate"
    export PYTHONPATH="${SCRIPTS_DIR}"
    cd "${SCRIPTS_DIR}"
    echo "=== ruff ==="
    python -m ruff check openemr_dr
    echo "=== mypy ==="
    python -m mypy openemr_dr --config-file openemr_dr/pyproject.toml
    echo "=== bandit ==="
    python -m bandit -r openemr_dr -c openemr_dr/pyproject.toml -q
    echo "=== pytest ==="
    python -m pytest openemr_dr/tests/ \
      -m "not floci" \
      --cov=openemr_dr \
      --cov-config=openemr_dr/pyproject.toml \
      --cov-report=term-missing \
      --cov-report=html:openemr_dr/htmlcov \
      --cov-fail-under=90
    ;;
  warp)
    "${SCRIPTS_DIR}/validate-python-requirements.sh" warp
    "${SCRIPTS_DIR}/install-python-dev.sh" warp
    # shellcheck disable=SC1091
    source "${SCRIPTS_DIR}/../warp/.venv/bin/activate"
    cd "${SCRIPTS_DIR}/../warp"
    echo "=== pytest ==="
    pytest tests/ -v \
      -m "not floci" \
      --cov=warp \
      --cov-report=term-missing \
      --cov-report=html \
      --ignore=tests/benchmarks \
      --cov-fail-under=90
    echo "=== black ==="
    black warp/ tests/ --line-length 127 --check --diff
    echo "=== flake8 ==="
    flake8 warp/ tests/ --max-line-length=127 --extend-ignore=E203 --count --statistics
    echo "=== mypy ==="
    mypy warp/ --ignore-missing-imports
    echo "=== bandit ==="
    bandit -r warp/ -q -x '**/tests/**'
    ;;
  credential_rotation)
    "${SCRIPTS_DIR}/validate-python-requirements.sh" credential_rotation
    "${SCRIPTS_DIR}/install-python-dev.sh" credential_rotation
    # shellcheck disable=SC1091
    source "${SCRIPTS_DIR}/../tools/credential-rotation/.venv/bin/activate"
    cd "${SCRIPTS_DIR}/../tools/credential-rotation"
    echo "=== pytest ==="
    PYTHONPATH=src pytest tests/ -v \
      -m "not floci" \
      --cov=credential_rotation \
      --cov-report=term-missing \
      --cov-report=html \
      --cov-fail-under=90
    echo "=== black ==="
    black src/ tests/ --line-length 127 --check --diff
    echo "=== flake8 ==="
    flake8 src/ tests/ --max-line-length=127 --extend-ignore=E203 --count --statistics
    echo "=== mypy ==="
    mypy src/credential_rotation/ --ignore-missing-imports
    echo "=== bandit ==="
    bandit -r src/credential_rotation -c pyproject.toml -q
    ;;
  *)
    echo "Unknown project: ${PROJECT}" >&2
    exit 1
    ;;
esac
