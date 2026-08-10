# Shared helpers for Floci-backed BATS suites.

require_floci() {
  if [ -z "${AWS_ENDPOINT_URL:-}" ]; then
    skip "AWS_ENDPOINT_URL unset (Floci not configured)"
  fi
  if ! command -v aws >/dev/null 2>&1; then
    skip "aws CLI not installed"
  fi
}

floci_aws() {
  # Explicit endpoint keeps tests honest even if the shell env drifts.
  aws --endpoint-url "${AWS_ENDPOINT_URL}" "$@"
}
