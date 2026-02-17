#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# BATS Suite: scripts/quick-deploy.sh
# Purpose: Validate CLI help contract, every documented flag, skip-mode logic,
#          default configuration, and error handling for unknown options.
# Scope:   Invokes only --help and invalid-option paths.
# -----------------------------------------------------------------------------

load test_helper

setup() { cd "$PROJECT_ROOT"; }

SCRIPT="${SCRIPTS_DIR}/quick-deploy.sh"

# ── Executable & syntax ─────────────────────────────────────────────────────

@test "quick-deploy.sh is executable" {
  [ -x "$SCRIPT" ]
}

@test "quick-deploy.sh has valid bash syntax" {
  bash -n "$SCRIPT"
}

# ── Help contract ───────────────────────────────────────────────────────────

@test "--help exits 0" {
  run_script "quick-deploy.sh" "--help"
  assert_success
}

@test "--help shows usage information" {
  run_script "quick-deploy.sh" "--help"
  [[ "$output" =~ (Usage|USAGE|Options|options) ]]
}

# ── Help documents every flag ───────────────────────────────────────────────

@test "--help documents --cluster-name" {
  run_script "quick-deploy.sh" "--help"
  [[ "$output" =~ "cluster-name" ]]
}

@test "--help documents --aws-region" {
  run_script "quick-deploy.sh" "--help"
  [[ "$output" =~ "aws-region" ]]
}

@test "--help documents --skip-terraform" {
  run_script "quick-deploy.sh" "--help"
  [[ "$output" =~ "skip-terraform" ]]
}

@test "--help documents --skip-openemr" {
  run_script "quick-deploy.sh" "--help"
  [[ "$output" =~ "skip-openemr" ]]
}

@test "--help documents --skip-monitoring" {
  run_script "quick-deploy.sh" "--help"
  [[ "$output" =~ "skip-monitoring" ]]
}

# ── Error handling ──────────────────────────────────────────────────────────

@test "unknown option exits non-zero" {
  run_script "quick-deploy.sh" "--invalid"
  [ "$status" -ne 0 ]
}

@test "unknown option suggests help" {
  run_script "quick-deploy.sh" "--invalid"
  [[ "$output" =~ (help|Usage|usage) ]]
}

# ── Static analysis ────────────────────────────────────────────────────────

@test "script uses set -euo pipefail" {
  run grep 'set -euo pipefail' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "SKIP_TERRAFORM defaults to false" {
  run grep 'SKIP_TERRAFORM=false' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "SKIP_OPENEMR defaults to false" {
  run grep 'SKIP_OPENEMR=false' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "SKIP_MONITORING defaults to false" {
  run grep 'SKIP_MONITORING=false' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "NAMESPACE is set to 'openemr'" {
  run grep 'NAMESPACE="openemr"' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "MONITORING_NAMESPACE is set to 'monitoring'" {
  run grep 'MONITORING_NAMESPACE="monitoring"' "$SCRIPT"
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
  [[ "$output" =~ "--skip-terraform" ]]
  [[ "$output" =~ "--skip-openemr" ]]
  [[ "$output" =~ "--skip-monitoring" ]]
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
    log_info 'quick deploy info'
  "
  [[ "$output" =~ "quick deploy info" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: log_header outputs decorated header" {
  FUNC_FILE=$(extract_function "$SCRIPT" "log_header")
  run bash -c "
    CYAN='' NC=''
    source '$FUNC_FILE'
    log_header 'Phase 1'
  "
  [[ "$output" =~ "Phase 1" ]]
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
    log_success 'deploy complete'
  "
  [[ "$output" =~ "deploy complete" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: log_warning outputs formatted message" {
  FUNC_FILE=$(extract_function "$SCRIPT" "log_warning")
  run bash -c "
    YELLOW='' NC=''
    source '$FUNC_FILE'
    log_warning 'slow network'
  "
  [[ "$output" =~ "slow network" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: log_error outputs formatted message to stderr" {
  FUNC_FILE=$(extract_function "$SCRIPT" "log_error")
  run bash -c "
    RED='' NC=''
    source '$FUNC_FILE'
    log_error 'quick deploy error' 2>&1
  "
  [[ "$output" =~ "quick deploy error" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: log_step outputs step message" {
  FUNC_FILE=$(extract_function "$SCRIPT" "log_step")
  run bash -c "
    BLUE='' NC=''
    source '$FUNC_FILE'
    log_step 'Running terraform'
  "
  [[ "$output" =~ "Running terraform" ]]
  rm -f "$FUNC_FILE"
}

# ── UNIT: show_help depth ───────────────────────────────────────────────────

@test "UNIT: show_help documents --cluster-name flag" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_help")
  run bash -c "
    source '$FUNC_FILE'
    show_help
  "
  [[ "$output" =~ "--cluster-name" ]] || [[ "$output" =~ "cluster" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: show_help documents --skip-monitoring flag" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_help")
  run bash -c "
    source '$FUNC_FILE'
    show_help
  "
  [[ "$output" =~ "monitoring" ]] || [[ "$output" =~ "skip" ]]
  rm -f "$FUNC_FILE"
}
