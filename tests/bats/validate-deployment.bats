#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# BATS Suite: scripts/validate-deployment.sh
# Purpose: Validate startup behavior, check_command function, region validation
#          logic, dependency fail-fast, default config, and banner output.
# Scope:   Non-destructive checks of banner, input validation, and fail-fast logic.
# -----------------------------------------------------------------------------

load test_helper

setup() { cd "$PROJECT_ROOT"; }

SCRIPT="${SCRIPTS_DIR}/validate-deployment.sh"

# ── Executable & syntax ─────────────────────────────────────────────────────

@test "validate-deployment.sh is executable" {
  [ -x "$SCRIPT" ]
}

@test "validate-deployment.sh has valid bash syntax" {
  bash -n "$SCRIPT"
}

# ── Banner output ──────────────────────────────────────────────────────────

@test "prints validation banner on startup" {
  run_script "validate-deployment.sh"
  [[ "$output" =~ (OpenEMR Deployment Validation|Deployment Validation) ]]
}

# ── AWS_REGION handling ────────────────────────────────────────────────────

@test "warns on invalid AWS_REGION format" {
  run env AWS_REGION="invalid-region" bash "$SCRIPT"
  [[ "$output" =~ (Invalid AWS_REGION format|using default|Could not determine AWS region) ]]
}

@test "accepts valid AWS_REGION format" {
  # Valid format but won't have real Terraform state — still exercises the format validator
  run env AWS_REGION="eu-west-1" bash "$SCRIPT"
  # Should NOT say "Invalid AWS_REGION format"
  if [[ "$output" =~ "Invalid AWS_REGION format" ]]; then return 1; fi
}

# ── Fail-fast behavior ────────────────────────────────────────────────────

@test "fails fast when critical tools are unavailable" {
  run env PATH="/usr/bin:/bin" bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ (not installed|credentials invalid|Unable to connect|❌) ]]
}

# ── check_command function ─────────────────────────────────────────────────

@test "script defines check_command function" {
  run grep 'check_command()' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "check_command uses 'command -v' for tool detection" {
  run grep -A5 'check_command()' "$SCRIPT"
  [[ "$output" =~ "command -v" ]]
}

# ── get_aws_region function ────────────────────────────────────────────────

@test "get_aws_region is defined" {
  run grep 'get_aws_region()' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "get_aws_region checks Terraform state first" {
  run grep -A10 'get_aws_region()' "$SCRIPT"
  [[ "$output" =~ "terraform.tfstate" ]]
}

@test "get_aws_region validates region format with regex" {
  run grep -A30 'get_aws_region()' "$SCRIPT"
  [[ "$output" =~ 'a-z.*a-z.*0-9' ]]
}

@test "get_aws_region falls back to us-west-2" {
  run grep -A40 'get_aws_region()' "$SCRIPT"
  [[ "$output" =~ 'us-west-2' ]]
}

# ── Static analysis ────────────────────────────────────────────────────────

@test "script checks for kubectl" {
  run grep 'kubectl' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script checks for aws cli" {
  run grep '"aws"' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script checks for jq" {
  run grep '"jq"' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script defines TERRAFORM_DIR" {
  run grep 'TERRAFORM_DIR=' "$SCRIPT"
  [ "$status" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════
# Function-level unit tests
# These extract individual functions and test them in isolation with
# controlled inputs, avoiding any AWS/kubectl calls.
# ═══════════════════════════════════════════════════════════════════════════

@test "UNIT: check_command succeeds for 'bash' (always available)" {
  local func_file
  func_file=$(extract_function "$SCRIPT" "check_command")
  run bash -c '
    GREEN="\033[0;32m"; RED="\033[0;31m"; NC="\033[0m"
    source "'"$func_file"'"
    check_command "bash"
  '
  rm -f "$func_file"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "bash" ]]
  [[ "$output" =~ "installed" ]]
}

@test "UNIT: check_command fails for nonexistent tool" {
  local func_file
  func_file=$(extract_function "$SCRIPT" "check_command")
  run bash -c '
    GREEN="\033[0;32m"; RED="\033[0;31m"; NC="\033[0m"
    source "'"$func_file"'"
    check_command "nonexistent_tool_xyz_12345"
  '
  rm -f "$func_file"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "not installed" ]]
}

@test "UNIT: check_command succeeds for 'grep' (standard tool)" {
  local func_file
  func_file=$(extract_function "$SCRIPT" "check_command")
  run bash -c '
    GREEN="\033[0;32m"; RED="\033[0;31m"; NC="\033[0m"
    source "'"$func_file"'"
    check_command "grep"
  '
  rm -f "$func_file"
  [ "$status" -eq 0 ]
}

@test "UNIT: get_aws_region falls back to us-west-2 when no state exists" {
  local func_file
  func_file=$(extract_function "$SCRIPT" "get_aws_region")
  run bash -c '
    BLUE="\033[0;34m"; YELLOW="\033[1;33m"; NC="\033[0m"
    TERRAFORM_DIR="/tmp/nonexistent_terraform_dir_$$"
    AWS_REGION="us-west-2"
    source "'"$func_file"'"
    get_aws_region
    echo "$AWS_REGION"
  '
  rm -f "$func_file"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "us-west-2" ]]
}

@test "UNIT: get_aws_region validates region format rejects garbage" {
  local func_file
  func_file=$(extract_function "$SCRIPT" "get_aws_region")
  run bash -c '
    BLUE="\033[0;34m"; YELLOW="\033[1;33m"; NC="\033[0m"
    TERRAFORM_DIR="/tmp/nonexistent_terraform_dir_$$"
    AWS_REGION="not-a-valid-region-123"
    source "'"$func_file"'"
    get_aws_region
    echo "$AWS_REGION"
  '
  rm -f "$func_file"
  [ "$status" -eq 0 ]
  # Should fall back to us-west-2 since the format is invalid
  [[ "$output" =~ "us-west-2" ]]
}

# ── UNIT: check_command for multiple tools ──────────────────────────────────

@test "UNIT: check_command succeeds for 'cat' (standard tool)" {
  FUNC_FILE=$(extract_function "$SCRIPT" "check_command")
  run bash -c "
    GREEN='' RED='' NC=''
    source '$FUNC_FILE'
    check_command 'cat'
  "
  assert_success
  rm -f "$FUNC_FILE"
}

@test "UNIT: check_command succeeds for 'sed' (standard tool)" {
  FUNC_FILE=$(extract_function "$SCRIPT" "check_command")
  run bash -c "
    GREEN='' RED='' NC=''
    source '$FUNC_FILE'
    check_command 'sed'
  "
  assert_success
  rm -f "$FUNC_FILE"
}

# ── UNIT: main function structure ───────────────────────────────────────────

@test "UNIT: script defines provide_recommendations function" {
  run grep 'provide_recommendations()' "$SCRIPT"
  assert_success
}

@test "UNIT: script defines check_security_config function" {
  run grep 'check_security_config()' "$SCRIPT"
  assert_success
}

@test "UNIT: script defines check_required_resources function" {
  run grep 'check_required_resources()' "$SCRIPT"
  assert_success
}
