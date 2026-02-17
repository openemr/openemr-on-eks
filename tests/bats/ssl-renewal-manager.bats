#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# BATS Suite: scripts/ssl-renewal-manager.sh
# Purpose: Validate renewal-manager command routing, every documented subcommand,
#          prerequisite checks, and usage/failure behavior.
# Scope:   Invokes only no-args/invalid-command paths.
# -----------------------------------------------------------------------------

load test_helper

setup() { cd "$PROJECT_ROOT"; }

SCRIPT="${SCRIPTS_DIR}/ssl-renewal-manager.sh"

# ── Executable & syntax ─────────────────────────────────────────────────────

@test "ssl-renewal-manager.sh is executable" {
  [ -x "$SCRIPT" ]
}

@test "ssl-renewal-manager.sh has valid bash syntax" {
  bash -n "$SCRIPT"
}

# ── No-args shows usage ────────────────────────────────────────────────────

@test "no args shows Usage" {
  run_script "ssl-renewal-manager.sh"
  [[ "$output" =~ "Usage" ]]
}

# ── Usage documents all subcommands ────────────────────────────────────────

@test "usage mentions 'deploy' subcommand" {
  run_script "ssl-renewal-manager.sh"
  [[ "$output" =~ "deploy" ]]
}

@test "usage mentions 'status' subcommand" {
  run_script "ssl-renewal-manager.sh"
  [[ "$output" =~ "status" ]]
}

@test "usage mentions 'run-now' subcommand" {
  run_script "ssl-renewal-manager.sh"
  [[ "$output" =~ "run-now" ]]
}

@test "usage mentions 'logs' subcommand" {
  run_script "ssl-renewal-manager.sh"
  [[ "$output" =~ "logs" ]]
}

@test "usage mentions 'test' subcommand" {
  run_script "ssl-renewal-manager.sh"
  [[ "$output" =~ "test" ]]
}

@test "usage mentions 'cleanup' subcommand" {
  run_script "ssl-renewal-manager.sh"
  [[ "$output" =~ "cleanup" ]]
}

@test "usage mentions 'schedule' subcommand" {
  run_script "ssl-renewal-manager.sh"
  [[ "$output" =~ "schedule" ]]
}

# ── Error handling ──────────────────────────────────────────────────────────

@test "invalid subcommand exits non-zero" {
  run_script "ssl-renewal-manager.sh" "invalidcommand"
  [ "$status" -ne 0 ]
}

# ── Static analysis: prerequisites ─────────────────────────────────────────

@test "script defines check_prerequisites function" {
  run grep 'check_prerequisites()' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "check_prerequisites checks for kubectl" {
  run grep -A20 'check_prerequisites()' "$SCRIPT"
  [[ "$output" =~ "kubectl" ]]
}

@test "check_prerequisites checks for aws cli" {
  run grep -A20 'check_prerequisites()' "$SCRIPT"
  [[ "$output" =~ "aws" ]]
}

@test "check_prerequisites validates AWS credentials" {
  run grep -A30 'check_prerequisites()' "$SCRIPT"
  [[ "$output" =~ "get-caller-identity" ]]
}

@test "script defines print_usage function" {
  run grep 'print_usage()' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script defines get_aws_region function" {
  run grep 'get_aws_region()' "$SCRIPT"
  [ "$status" -eq 0 ]
}

# ── UNIT: print_usage ──────────────────────────────────────────────────────

@test "UNIT: print_usage prints Usage line" {
  FUNC_FILE=$(extract_function "$SCRIPT" "print_usage")
  run bash -c "
    source '$FUNC_FILE'
    print_usage
  "
  [[ "$output" =~ "Usage" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: print_usage lists all subcommands" {
  FUNC_FILE=$(extract_function "$SCRIPT" "print_usage")
  run bash -c "
    source '$FUNC_FILE'
    print_usage
  "
  [[ "$output" =~ "deploy" ]]
  [[ "$output" =~ "status" ]]
  [[ "$output" =~ "run-now" ]]
  [[ "$output" =~ "logs" ]]
  [[ "$output" =~ "test" ]]
  [[ "$output" =~ "cleanup" ]]
  [[ "$output" =~ "schedule" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: print_usage includes Examples section" {
  FUNC_FILE=$(extract_function "$SCRIPT" "print_usage")
  run bash -c "
    source '$FUNC_FILE'
    print_usage
  "
  [[ "$output" =~ "Examples" ]]
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

@test "UNIT: get_aws_region respects valid AWS_REGION env" {
  FUNC_FILE=$(extract_function "$SCRIPT" "get_aws_region")
  run bash -c "
    BLUE='' NC='' YELLOW=''
    TERRAFORM_DIR='/nonexistent/path'
    AWS_REGION='ap-southeast-1'
    source '$FUNC_FILE'
    get_aws_region
    echo \"\$AWS_REGION\"
  "
  [[ "$output" =~ "ap-southeast-1" ]]
  rm -f "$FUNC_FILE"
}

# ── UNIT: print_usage depth ─────────────────────────────────────────────────

@test "UNIT: print_usage documents deploy subcommand" {
  FUNC_FILE=$(extract_function "$SCRIPT" "print_usage")
  run bash -c "
    source '$FUNC_FILE'
    print_usage
  "
  [[ "$output" =~ "deploy" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: print_usage documents check-status subcommand" {
  FUNC_FILE=$(extract_function "$SCRIPT" "print_usage")
  run bash -c "
    source '$FUNC_FILE'
    print_usage
  "
  [[ "$output" =~ "check-status" ]] || [[ "$output" =~ "status" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: print_usage documents cleanup subcommand" {
  FUNC_FILE=$(extract_function "$SCRIPT" "print_usage")
  run bash -c "
    source '$FUNC_FILE'
    print_usage
  "
  [[ "$output" =~ "cleanup" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: get_aws_region rejects invalid region format" {
  FUNC_FILE=$(extract_function "$SCRIPT" "get_aws_region")
  run bash -c "
    BLUE='' NC='' YELLOW=''
    TERRAFORM_DIR='/nonexistent/path'
    AWS_REGION='BOGUS'
    source '$FUNC_FILE'
    get_aws_region
    echo \"\$AWS_REGION\"
  "
  [[ "$output" =~ "us-west-2" ]]
  rm -f "$FUNC_FILE"
}
