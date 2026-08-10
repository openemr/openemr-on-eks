#!/usr/bin/env bash
# Export AWS client settings that point SDKs/CLI at a local Floci instance.
# Usage: source tests/floci/env.sh
# Optional overrides: FLOCI_ENDPOINT, FLOCI_REGION, FLOCI_VERSION

_FLOCI_ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_FLOCI_PROJECT_ROOT="$(cd "${_FLOCI_ENV_DIR}/../.." && pwd)"

if [ -z "${FLOCI_VERSION:-}" ] && command -v yq >/dev/null 2>&1 && [ -f "${_FLOCI_PROJECT_ROOT}/versions.yaml" ]; then
  FLOCI_VERSION="$(yq eval '.applications.floci.current' "${_FLOCI_PROJECT_ROOT}/versions.yaml" 2>/dev/null || true)"
fi
export FLOCI_VERSION="${FLOCI_VERSION:-1.6.0}"

export AWS_ENDPOINT_URL="${FLOCI_ENDPOINT:-http://localhost:4566}"
export AWS_DEFAULT_REGION="${FLOCI_REGION:-us-east-1}"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
# Prevent profile/credential file interference in CI and local debug shells.
export AWS_CONFIG_FILE="${AWS_CONFIG_FILE:-/dev/null}"
export AWS_SHARED_CREDENTIALS_FILE="${AWS_SHARED_CREDENTIALS_FILE:-/dev/null}"
export AWS_EC2_METADATA_DISABLED="${AWS_EC2_METADATA_DISABLED:-true}"

unset AWS_PROFILE AWS_SESSION_TOKEN AWS_SECURITY_TOKEN 2>/dev/null || true

echo "Floci env ready: AWS_ENDPOINT_URL=${AWS_ENDPOINT_URL} FLOCI_VERSION=${FLOCI_VERSION}" >&2
