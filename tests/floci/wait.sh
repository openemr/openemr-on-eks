#!/usr/bin/env bash
# Poll Floci readiness until the emulator accepts AWS API traffic.
# Usage: ./tests/floci/wait.sh [endpoint] [timeout_seconds]

set -euo pipefail

ENDPOINT="${1:-${AWS_ENDPOINT_URL:-http://localhost:4566}}"
TIMEOUT_SECONDS="${2:-${FLOCI_WAIT_TIMEOUT:-180}}"
INIT_URL="${ENDPOINT%/}/_floci/init"
HEALTH_URL="${ENDPOINT%/}/_floci/health"
LOCALSTACK_HEALTH_URL="${ENDPOINT%/}/_localstack/health"

dump_diagnostics() {
  echo "--- Floci wait diagnostics ---" >&2
  echo "endpoint=${ENDPOINT}" >&2
  curl -sS -m 3 -D- "${INIT_URL}" -o /tmp/floci-init.body 2>&1 | head -40 >&2 || true
  echo "init body:" >&2
  head -c 500 /tmp/floci-init.body 2>/dev/null >&2 || true
  echo >&2
  if command -v docker >/dev/null 2>&1; then
    echo "compose ps:" >&2
    docker compose -f "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/compose.yaml" ps 2>&1 | head -20 >&2 || true
    echo "container logs (tail):" >&2
    docker compose -f "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/compose.yaml" logs --tail=80 2>&1 | tail -80 >&2 || true
  fi
}

endpoint_tcp_open() {
  local host port
  host="$(echo "${ENDPOINT}" | sed -E 's#^[a-zA-Z]+://##' | cut -d/ -f1 | cut -d: -f1)"
  port="$(echo "${ENDPOINT}" | sed -E 's#^[a-zA-Z]+://##' | cut -d/ -f1 | awk -F: '{print ($2=="" ? "4566" : $2)}')"
  if command -v nc >/dev/null 2>&1; then
    nc -z -w 1 "${host}" "${port}" >/dev/null 2>&1
    return $?
  fi
  # Bash /dev/tcp fallback
  (exec 3<>"/dev/tcp/${host}/${port}") >/dev/null 2>&1
}

deadline=$((SECONDS + TIMEOUT_SECONDS))
echo "Waiting for Floci readiness at ${INIT_URL} (timeout ${TIMEOUT_SECONDS}s)..." >&2

# Give compose a moment after `up -d` before the first probe.
sleep 2

while (( SECONDS < deadline )); do
  if endpoint_tcp_open; then
    # Prefer STS — that is what suites need, regardless of init JSON shape.
    if AWS_ENDPOINT_URL="${ENDPOINT}" AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}" \
       AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}" AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}" \
       AWS_EC2_METADATA_DISABLED=true AWS_PAGER="" \
       aws sts get-caller-identity >/dev/null 2>&1; then
      echo "Floci accepted STS get-caller-identity; ready." >&2
      exit 0
    fi

    response="$(curl -fsS -m 3 "${INIT_URL}" 2>/dev/null || true)"
    if [ -n "${response}" ] && echo "${response}" | grep -Eqi \
      '"ready"[[:space:]]*:[[:space:]]*true|"completed"[[:space:]]*:[[:space:]]*true|"status"[[:space:]]*:[[:space:]]*"ready"|"initialized"[[:space:]]*:[[:space:]]*true'; then
      echo "Floci init endpoint reports ready." >&2
      exit 0
    fi

    if curl -fsS -m 3 "${HEALTH_URL}" >/dev/null 2>&1 \
      || curl -fsS -m 3 "${LOCALSTACK_HEALTH_URL}" >/dev/null 2>&1; then
      # Health alone is not enough — keep looping until STS works, but log progress.
      echo "Floci health endpoint responded; waiting for STS..." >&2
    fi
  else
    echo "Port not open yet at ${ENDPOINT}..." >&2
  fi

  sleep 2
done

echo "ERROR: Floci did not become ready within ${TIMEOUT_SECONDS}s at ${ENDPOINT}" >&2
dump_diagnostics
exit 1
