#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# BATS Suite: oidc_provider/scripts/*.sh
# Purpose: Validate CLI contract and safe failure paths for all OIDC scripts,
#          including syntax, executable bits, help/option parsing, static
#          constants, and prerequisite validation logic.
# Scope:   Syntax checks and help-path invocations only.
# -----------------------------------------------------------------------------

load test_helper

setup() { cd "$PROJECT_ROOT"; }

OIDC_DIR="${PROJECT_ROOT}/oidc_provider/scripts"

# ── Executable & syntax ─────────────────────────────────────────────────────

@test "oidc deploy.sh is executable" {
  [ -x "${OIDC_DIR}/deploy.sh" ]
}

@test "oidc validate.sh is executable" {
  [ -x "${OIDC_DIR}/validate.sh" ]
}

@test "oidc destroy.sh is executable" {
  [ -x "${OIDC_DIR}/destroy.sh" ]
}

@test "oidc deploy.sh has valid bash syntax" {
  bash -n "${OIDC_DIR}/deploy.sh"
}

@test "oidc validate.sh has valid bash syntax" {
  bash -n "${OIDC_DIR}/validate.sh"
}

@test "oidc destroy.sh has valid bash syntax" {
  bash -n "${OIDC_DIR}/destroy.sh"
}

# ── Destroy help contract ──────────────────────────────────────────────────

@test "oidc destroy --help exits 0" {
  run_script_from "oidc_provider/scripts" "destroy.sh" "--help"
  assert_success
}

@test "oidc destroy --help shows Usage" {
  run_script_from "oidc_provider/scripts" "destroy.sh" "--help"
  [[ "$output" =~ "Usage" ]]
}

@test "oidc destroy --help documents --force" {
  run_script_from "oidc_provider/scripts" "destroy.sh" "--help"
  [[ "$output" =~ "--force" ]]
}

@test "oidc destroy --help includes WARNING" {
  run_script_from "oidc_provider/scripts" "destroy.sh" "--help"
  [[ "$output" =~ (WARNING|permanently delete) ]]
}

# ── Destroy error handling ─────────────────────────────────────────────────

@test "oidc destroy unknown option fails with guidance" {
  run_script_from "oidc_provider/scripts" "destroy.sh" "--invalid"
  [ "$status" -ne 0 ]
  [[ "$output" =~ (Unknown option|help|Usage|usage) ]]
}

# ── Static analysis: all scripts ───────────────────────────────────────────

@test "all OIDC scripts use set -euo pipefail" {
  for script in deploy.sh validate.sh destroy.sh; do
    run grep 'set -euo pipefail' "${OIDC_DIR}/${script}"
    [ "$status" -eq 0 ]
  done
}

@test "destroy.sh defines check_prerequisites function" {
  run grep 'check_prerequisites\|validate_prerequisites' "${OIDC_DIR}/destroy.sh"
  [ "$status" -eq 0 ]
}

@test "deploy.sh references Terraform" {
  run grep -i 'terraform' "${OIDC_DIR}/deploy.sh"
  [ "$status" -eq 0 ]
}

@test "OIDC terraform directory exists" {
  [ -d "${PROJECT_ROOT}/oidc_provider/terraform" ]
}

# ── UNIT: log functions (oidc deploy.sh) ────────────────────────────────────

@test "UNIT: oidc deploy log_info outputs message" {
  FUNC_FILE=$(extract_function "${OIDC_DIR}/deploy.sh" "log_info")
  run bash -c "
    BLUE='' NC=''
    source '$FUNC_FILE'
    log_info 'oidc info test'
  "
  [[ "$output" =~ "oidc info test" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: oidc deploy log_header outputs decorated message" {
  FUNC_FILE=$(extract_function "${OIDC_DIR}/deploy.sh" "log_header")
  run bash -c "
    CYAN='' NC=''
    source '$FUNC_FILE'
    log_header 'OIDC Setup'
  "
  [[ "$output" =~ "OIDC Setup" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: oidc deploy log_error outputs to stderr" {
  FUNC_FILE=$(extract_function "${OIDC_DIR}/deploy.sh" "log_error")
  run bash -c "
    RED='' NC=''
    source '$FUNC_FILE'
    log_error 'oidc error test' 2>&1
  "
  [[ "$output" =~ "oidc error test" ]]
  rm -f "$FUNC_FILE"
}

# ── UNIT: get_aws_region (oidc deploy.sh) ───────────────────────────────────

@test "UNIT: oidc deploy get_aws_region falls back to us-west-2" {
  FUNC_FILE=$(extract_function "${OIDC_DIR}/deploy.sh" "get_aws_region")
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

@test "UNIT: oidc deploy get_aws_region respects valid env" {
  FUNC_FILE=$(extract_function "${OIDC_DIR}/deploy.sh" "get_aws_region")
  run bash -c "
    BLUE='' NC='' YELLOW=''
    TERRAFORM_DIR='/nonexistent/path'
    AWS_REGION='us-east-1'
    source '$FUNC_FILE'
    get_aws_region
    echo \"\$AWS_REGION\"
  "
  [[ "$output" =~ "us-east-1" ]]
  rm -f "$FUNC_FILE"
}

# ── UNIT: oidc log functions ────────────────────────────────────────────────

@test "UNIT: oidc deploy log_success outputs message" {
  FUNC_FILE=$(extract_function "${OIDC_DIR}/deploy.sh" "log_success")
  run bash -c "
    GREEN='' NC=''
    source '$FUNC_FILE'
    log_success 'OIDC deployed'
  "
  [[ "$output" =~ "OIDC deployed" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: oidc deploy log_warning outputs message" {
  FUNC_FILE=$(extract_function "${OIDC_DIR}/deploy.sh" "log_warning")
  run bash -c "
    YELLOW='' NC=''
    source '$FUNC_FILE'
    log_warning 'OIDC warning'
  "
  [[ "$output" =~ "OIDC warning" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: oidc deploy log_error outputs message to stderr" {
  FUNC_FILE=$(extract_function "${OIDC_DIR}/deploy.sh" "log_error")
  run bash -c "
    RED='' NC=''
    source '$FUNC_FILE'
    log_error 'OIDC failed' 2>&1
  "
  [[ "$output" =~ "OIDC failed" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: oidc deploy log_step outputs step message" {
  FUNC_FILE=$(extract_function "${OIDC_DIR}/deploy.sh" "log_step")
  run bash -c "
    BLUE='' NC=''
    source '$FUNC_FILE'
    log_step 'Validating config'
  "
  [[ "$output" =~ "Validating config" ]]
  rm -f "$FUNC_FILE"
}

# ── UNIT: oidc destroy confirm_destruction ──────────────────────────────────

@test "UNIT: oidc destroy confirm_destruction skips in force mode" {
  FUNC_FILE=$(extract_function "${OIDC_DIR}/destroy.sh" "confirm_destruction")
  run bash -c "
    FORCE_MODE=true
    log_warning() { echo \"WARN: \$*\"; }
    log_info() { echo \"INFO: \$*\"; }
    source '$FUNC_FILE'
    confirm_destruction
    echo 'CONTINUED'
  "
  [[ "$output" =~ "CONTINUED" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: oidc destroy get_aws_region falls back to default" {
  FUNC_FILE=$(extract_function "${OIDC_DIR}/destroy.sh" "get_aws_region")
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
