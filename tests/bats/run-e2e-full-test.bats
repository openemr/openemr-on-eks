#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# BATS Suite: scripts/run-e2e-full-test.sh
# Purpose: Validate portable AWS credential selection without starting E2E.
# -----------------------------------------------------------------------------

load test_helper

setup() { cd "$PROJECT_ROOT"; }

SCRIPT="${SCRIPTS_DIR}/run-e2e-full-test.sh"

@test "run-e2e-full-test.sh has valid bash syntax" {
  bash -n "$SCRIPT"
}

@test "wrapper has no account-specific AWS profile default" {
  ! grep -Eq '[0-9]{12}_AdministratorAccess' "$SCRIPT"
}

@test "wrapper falls back from AWS_PROFILE_NAME to AWS_PROFILE" {
  grep -Fq 'AWS_PROFILE_NAME="${AWS_PROFILE_NAME:-${AWS_PROFILE:-}}"' "$SCRIPT"
}

@test "UNIT: explicit wrapper profile is exported for AWS commands" {
  local func_file
  func_file=$(extract_function "$SCRIPT" "load_credentials")
  run bash -c '
    AWS_PROFILE_NAME="team-profile"
    unset AWS_PROFILE
    aws() { [ "$AWS_PROFILE" = "team-profile" ]; }
    source "$1"
    load_credentials
    printf "%s\n" "$AWS_PROFILE"
  ' _ "$func_file"
  assert_success
  [ "$output" = "team-profile" ]
  rm -f "$func_file"
}

@test "UNIT: omitted profile uses the default AWS credential chain" {
  local func_file
  func_file=$(extract_function "$SCRIPT" "load_credentials")
  run bash -c '
    AWS_PROFILE_NAME=""
    unset AWS_PROFILE
    aws() { [ -z "${AWS_PROFILE+x}" ]; }
    source "$1"
    load_credentials
    [ -z "${AWS_PROFILE+x}" ]
  ' _ "$func_file"
  assert_success
  rm -f "$func_file"
}
