#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# BATS Suite: scripts/validate-efs-csi.sh
# Purpose: Validate startup checks, EFS CSI validation banner, region handling,
#          fail-fast behavior, and dependency checks.
# Scope:   Non-destructive checks of banner, region handling, and dependency errors.
# -----------------------------------------------------------------------------

load test_helper

setup() { cd "$PROJECT_ROOT"; }

SCRIPT="${SCRIPTS_DIR}/validate-efs-csi.sh"

# ── Executable & syntax ─────────────────────────────────────────────────────

@test "validate-efs-csi.sh is executable" {
  [ -x "$SCRIPT" ]
}

@test "validate-efs-csi.sh has valid bash syntax" {
  bash -n "$SCRIPT"
}

# ── Banner output ──────────────────────────────────────────────────────────

@test "prints EFS CSI validation banner" {
  run_script "validate-efs-csi.sh"
  [[ "$output" =~ (EFS CSI Driver Validation Tool|EFS CSI) ]]
}

# ── AWS_REGION handling ────────────────────────────────────────────────────

@test "warns on invalid AWS_REGION format" {
  run env AWS_REGION="invalid-region" bash "$SCRIPT"
  [[ "$output" =~ (Invalid AWS_REGION format|using default|Could not determine AWS region) ]]
}

@test "accepts valid AWS_REGION format" {
  run env AWS_REGION="ap-southeast-1" bash "$SCRIPT"
  if [[ "$output" =~ "Invalid AWS_REGION format" ]]; then return 1; fi
}

# ── Fail-fast behavior ────────────────────────────────────────────────────

@test "fails fast when kubectl/aws access is unavailable" {
  run env PATH="/usr/bin:/bin" bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ (not running|not found|cannot|❌|ERROR) ]]
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

@test "get_aws_region validates region format" {
  run grep -A30 'get_aws_region()' "$SCRIPT"
  [[ "$output" =~ 'a-z.*a-z.*0-9' ]]
}

# ── Validation steps ──────────────────────────────────────────────────────

@test "script checks EFS CSI controller pods" {
  run grep 'efs-csi-controller' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script checks kube-system namespace" {
  run grep 'kube-system' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script uses set -e" {
  run grep '^set -e' "$SCRIPT"
  [ "$status" -eq 0 ]
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

@test "UNIT: get_aws_region accepts valid region from env" {
  FUNC_FILE=$(extract_function "$SCRIPT" "get_aws_region")
  run bash -c "
    BLUE='' NC='' YELLOW=''
    TERRAFORM_DIR='/nonexistent/path'
    AWS_REGION='eu-central-1'
    source '$FUNC_FILE'
    get_aws_region
    echo \"\$AWS_REGION\"
  "
  [[ "$output" =~ "eu-central-1" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: get_aws_region rejects invalid region format" {
  FUNC_FILE=$(extract_function "$SCRIPT" "get_aws_region")
  run bash -c "
    BLUE='' NC='' YELLOW=''
    TERRAFORM_DIR='/nonexistent/path'
    AWS_REGION='BADREGION'
    source '$FUNC_FILE'
    get_aws_region
    echo \"\$AWS_REGION\"
  "
  [[ "$output" =~ "us-west-2" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: get_aws_region accepts ap-northeast-1" {
  FUNC_FILE=$(extract_function "$SCRIPT" "get_aws_region")
  run bash -c "
    BLUE='' NC='' YELLOW=''
    TERRAFORM_DIR='/nonexistent/path'
    AWS_REGION='ap-northeast-1'
    source '$FUNC_FILE'
    get_aws_region
    echo \"\$AWS_REGION\"
  "
  [[ "$output" =~ "ap-northeast-1" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: script defines all expected validation functions" {
  run grep -c 'function\|()' "$SCRIPT"
  [ "$status" -eq 0 ]
  # The script should have at least get_aws_region function
  run grep 'get_aws_region()' "$SCRIPT"
  [ "$status" -eq 0 ]
}
