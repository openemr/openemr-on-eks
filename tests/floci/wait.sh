#!/usr/bin/env bash
# Poll Floci readiness endpoint until the emulator accepts traffic.
# Usage: ./tests/floci/wait.sh [endpoint] [timeout_seconds]

set -euo pipefail

ENDPOINT="${1:-${AWS_ENDPOINT_URL:-http://localhost:4566}}"
TIMEOUT_SECONDS="${2:-${FLOCI_WAIT_TIMEOUT:-120}}"
INIT_URL="${ENDPOINT%/}/_floci/init"

deadline=$((SECONDS + TIMEOUT_SECONDS))
echo "Waiting for Floci readiness at ${INIT_URL} (timeout ${TIMEOUT_SECONDS}s)..." >&2

while (( SECONDS < deadline )); do
  if response="$(curl -fsS "${INIT_URL}" 2>/dev/null || true)"; then
    if echo "${response}" | grep -Eqi '"ready"[[:space:]]*:[[:space:]]*true|"completed"[[:space:]]*:[[:space:]]*true|"status"[[:space:]]*:[[:space:]]*"ready"'; then
      echo "Floci is ready." >&2
      exit 0
    fi
    # Some builds expose a simpler ready document or empty/ok body once up.
    if curl -fsS "${ENDPOINT%/}/_localstack/health" >/dev/null 2>&1 \
      || curl -fsS "${ENDPOINT%/}/_floci/health" >/dev/null 2>&1; then
      echo "Floci health endpoint responded; treating as ready." >&2
      exit 0
    fi
  fi

  # Fallback: STS should answer once the router is up.
  if AWS_ENDPOINT_URL="${ENDPOINT}" AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}" \
     AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}" AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}" \
     AWS_EC2_METADATA_DISABLED=true \
     aws sts get-caller-identity >/dev/null 2>&1; then
    echo "Floci accepted STS get-caller-identity; treating as ready." >&2
    exit 0
  fi

  sleep 2
done

echo "ERROR: Floci did not become ready within ${TIMEOUT_SECONDS}s at ${ENDPOINT}" >&2
exit 1
