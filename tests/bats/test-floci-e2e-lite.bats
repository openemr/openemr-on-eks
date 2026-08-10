#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# BATS Suite: scripts/test-floci-e2e-lite.sh
# Purpose: Validate CLI contract for Floci e2e-lite without requiring Floci.
# Scope:   Help/usage only — live scenario runs in the floci-e2e-lite CI job.
# -----------------------------------------------------------------------------

load test_helper

@test "test-floci-e2e-lite.sh --help exits 0 and documents Floci" {
  run_script test-floci-e2e-lite.sh --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Floci"* ]] || [[ "$output" == *"AWS_ENDPOINT_URL"* ]]
}

@test "test-floci-e2e-lite.sh rejects unknown options" {
  run_script test-floci-e2e-lite.sh --not-a-real-flag
  [ "$status" -ne 0 ]
}

@test "test-floci-e2e-lite.sh fails clearly without AWS_ENDPOINT_URL" {
  run bash -c 'env -u AWS_ENDPOINT_URL -u FLOCI_ENDPOINT bash "'"${SCRIPTS_DIR}"'/test-floci-e2e-lite.sh" 2>&1'
  [ "$status" -ne 0 ]
  [[ "$output" == *"AWS_ENDPOINT_URL"* ]]
}
