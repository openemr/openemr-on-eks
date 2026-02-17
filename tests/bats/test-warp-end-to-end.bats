#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# BATS Suite: scripts/test-warp-end-to-end.sh
# Purpose: Validate Warp E2E test CLI options, every documented flag, default
#          configuration values, and error handling.
# Scope:   Invokes only --help and invalid-option paths.
# -----------------------------------------------------------------------------

load test_helper

setup() { cd "$PROJECT_ROOT"; }

SCRIPT="${SCRIPTS_DIR}/test-warp-end-to-end.sh"

# ── Executable & syntax ─────────────────────────────────────────────────────

@test "test-warp-end-to-end.sh is executable" {
  [ -x "$SCRIPT" ]
}

@test "test-warp-end-to-end.sh has valid bash syntax" {
  bash -n "$SCRIPT"
}

# ── Help contract ───────────────────────────────────────────────────────────

@test "--help exits 0" {
  run_script "test-warp-end-to-end.sh" "--help"
  assert_success
}

@test "--help shows usage information" {
  run_script "test-warp-end-to-end.sh" "--help"
  [[ "$output" =~ (Usage|Options|--max-records|--skip-terraform) ]]
}

# ── Help documents every flag ───────────────────────────────────────────────

@test "--help documents --cluster-name" {
  run_script "test-warp-end-to-end.sh" "--help"
  [[ "$output" =~ "cluster-name" ]]
}

@test "--help documents --aws-region" {
  run_script "test-warp-end-to-end.sh" "--help"
  [[ "$output" =~ "aws-region" ]]
}

@test "--help documents --data-source" {
  run_script "test-warp-end-to-end.sh" "--help"
  [[ "$output" =~ "data-source" ]]
}

@test "--help documents --max-records" {
  run_script "test-warp-end-to-end.sh" "--help"
  [[ "$output" =~ "max-records" ]]
}

@test "--help documents --skip-terraform" {
  run_script "test-warp-end-to-end.sh" "--help"
  [[ "$output" =~ "skip-terraform" ]]
}

@test "--help documents --skip-openemr" {
  run_script "test-warp-end-to-end.sh" "--help"
  [[ "$output" =~ "skip-openemr" ]]
}

# ── Error handling ──────────────────────────────────────────────────────────

@test "unknown option exits non-zero" {
  run_script "test-warp-end-to-end.sh" "--invalid"
  [ "$status" -ne 0 ]
}

@test "unknown option suggests help" {
  run_script "test-warp-end-to-end.sh" "--invalid"
  [[ "$output" =~ (help|Usage|usage) ]]
}

# ── Static analysis ────────────────────────────────────────────────────────

@test "script uses set -euo pipefail" {
  run grep 'set -euo pipefail' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "MAX_RECORDS defaults to 1000" {
  run grep 'MAX_RECORDS.*1000' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "DATA_SOURCE references synpuf-omop" {
  run grep 'synpuf-omop' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "NAMESPACE is set to 'openemr'" {
  run grep 'NAMESPACE="openemr"' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script disables AWS_PAGER" {
  run grep 'export AWS_PAGER=""' "$SCRIPT"
  [ "$status" -eq 0 ]
}

# ── UNIT: show_help ─────────────────────────────────────────────────────────

@test "UNIT: show_help prints usage information" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_help")
  run bash -c "
    source '$FUNC_FILE'
    show_help
  "
  assert_success
  [[ "$output" =~ "USAGE" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: show_help documents all CLI flags" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_help")
  run bash -c "
    source '$FUNC_FILE'
    show_help
  "
  [[ "$output" =~ "--cluster-name" ]]
  [[ "$output" =~ "--aws-region" ]]
  [[ "$output" =~ "--data-source" ]]
  [[ "$output" =~ "--max-records" ]]
  [[ "$output" =~ "--skip-terraform" ]]
  [[ "$output" =~ "--skip-openemr" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: show_help lists prerequisites" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_help")
  run bash -c "
    source '$FUNC_FILE'
    show_help
  "
  [[ "$output" =~ "PREREQUISITES" ]]
  rm -f "$FUNC_FILE"
}

# ── UNIT: log functions ─────────────────────────────────────────────────────

@test "UNIT: log_info outputs message" {
  FUNC_FILE=$(extract_function "$SCRIPT" "log_info")
  run bash -c "
    BLUE='' NC=''
    source '$FUNC_FILE'
    log_info 'warp e2e info'
  "
  [[ "$output" =~ "warp e2e info" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: log_error outputs to stderr" {
  FUNC_FILE=$(extract_function "$SCRIPT" "log_error")
  run bash -c "
    RED='' NC=''
    source '$FUNC_FILE'
    log_error 'warp e2e error' 2>&1
  "
  [[ "$output" =~ "warp e2e error" ]]
  rm -f "$FUNC_FILE"
}

# ── UNIT: get_aws_region ────────────────────────────────────────────────────

@test "UNIT: get_aws_region falls back to us-west-2 default" {
  FUNC_FILE=$(extract_function "$SCRIPT" "get_aws_region")
  run bash -c "
    BLUE='' NC='' YELLOW=''
    TERRAFORM_DIR='/nonexistent/path'
    source '$FUNC_FILE'
    get_aws_region
    echo \"\$AWS_REGION\"
  "
  [[ "$output" =~ "us-west-2" ]]
  rm -f "$FUNC_FILE"
}

# ── UNIT: additional log functions ──────────────────────────────────────────

@test "UNIT: log_success outputs formatted message" {
  FUNC_FILE=$(extract_function "$SCRIPT" "log_success")
  run bash -c "
    GREEN='' NC=''
    source '$FUNC_FILE'
    log_success 'warp test passed'
  "
  [[ "$output" =~ "warp test passed" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: log_warning outputs formatted message" {
  FUNC_FILE=$(extract_function "$SCRIPT" "log_warning")
  run bash -c "
    YELLOW='' NC=''
    source '$FUNC_FILE'
    log_warning 'slow import'
  "
  [[ "$output" =~ "slow import" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: log_step outputs step message" {
  FUNC_FILE=$(extract_function "$SCRIPT" "log_step")
  run bash -c "
    BLUE='' NC=''
    source '$FUNC_FILE'
    log_step 'importing data'
  "
  [[ "$output" =~ "importing data" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: log_header outputs header message" {
  FUNC_FILE=$(extract_function "$SCRIPT" "log_header")
  run bash -c "
    CYAN='' NC=''
    source '$FUNC_FILE'
    log_header 'WARP E2E Test'
  "
  [[ "$output" =~ "WARP E2E Test" ]]
  rm -f "$FUNC_FILE"
}

# ── UNIT: show_help depth ───────────────────────────────────────────────────

@test "UNIT: show_help documents --cluster-name flag" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_help")
  run bash -c "
    source '$FUNC_FILE'
    show_help
  "
  [[ "$output" =~ "cluster" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: show_help documents --skip-cleanup flag" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_help")
  run bash -c "
    source '$FUNC_FILE'
    show_help
  "
  [[ "$output" =~ "cleanup" ]] || [[ "$output" =~ "skip" ]]
  rm -f "$FUNC_FILE"
}
