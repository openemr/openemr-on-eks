#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# BATS Suite: scripts/cluster-security-manager.sh
# Purpose: Validate command routing, every documented subcommand, usage output,
#          IP detection function, and error handling for invalid commands.
# Scope:   Invokes only no-args/invalid-command paths.
# -----------------------------------------------------------------------------

load test_helper

setup() { cd "$PROJECT_ROOT"; }

SCRIPT="${SCRIPTS_DIR}/cluster-security-manager.sh"

# ── Executable & syntax ─────────────────────────────────────────────────────

@test "cluster-security-manager.sh is executable" {
  [ -x "$SCRIPT" ]
}

@test "cluster-security-manager.sh has valid bash syntax" {
  bash -n "$SCRIPT"
}

# ── No-args shows usage ────────────────────────────────────────────────────

@test "no args shows Usage" {
  run_script "cluster-security-manager.sh"
  [[ "$output" =~ "Usage" ]]
}

# ── Usage documents all subcommands ────────────────────────────────────────

@test "usage mentions 'enable' subcommand" {
  run_script "cluster-security-manager.sh"
  [[ "$output" =~ "enable" ]]
}

@test "usage mentions 'disable' subcommand" {
  run_script "cluster-security-manager.sh"
  [[ "$output" =~ "disable" ]]
}

@test "usage mentions 'status' subcommand" {
  run_script "cluster-security-manager.sh"
  [[ "$output" =~ "status" ]]
}

@test "usage mentions 'auto-disable' subcommand" {
  run_script "cluster-security-manager.sh"
  [[ "$output" =~ "auto-disable" ]]
}

@test "usage mentions 'check-ip' subcommand" {
  run_script "cluster-security-manager.sh"
  [[ "$output" =~ "check-ip" ]]
}

@test "usage mentions security best practice" {
  run_script "cluster-security-manager.sh"
  [[ "$output" =~ (Security|security|public access) ]]
}

@test "usage mentions CLUSTER_UPDATE_TIMEOUT env var" {
  run_script "cluster-security-manager.sh"
  [[ "$output" =~ "CLUSTER_UPDATE_TIMEOUT" ]]
}

# ── Error handling ──────────────────────────────────────────────────────────

@test "invalid subcommand exits non-zero" {
  run_script "cluster-security-manager.sh" "invalidcommand"
  [ "$status" -ne 0 ]
}

# ── Static analysis ────────────────────────────────────────────────────────

@test "script defines show_usage function" {
  run grep 'show_usage()' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script defines get_current_ip function" {
  run grep 'get_current_ip()' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "get_current_ip uses AWS CheckIP as primary source" {
  run grep -A3 'get_current_ip()' "$SCRIPT"
  [[ "$output" =~ "checkip.amazonaws.com" ]]
}

@test "get_current_ip has fallback to Akamai" {
  run grep -A3 'get_current_ip()' "$SCRIPT"
  [[ "$output" =~ "akamai" ]]
}

@test "script defines get_allowed_ips function" {
  run grep 'get_allowed_ips()' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script defines get_aws_region function" {
  run grep 'get_aws_region()' "$SCRIPT"
  [ "$status" -eq 0 ]
}

# ── UNIT: show_usage ────────────────────────────────────────────────────────

@test "UNIT: show_usage prints subcommand list" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_usage")
  run bash -c "
    source '$FUNC_FILE'
    show_usage
  "
  [[ "$output" =~ "Usage" ]]
  [[ "$output" =~ "enable" ]]
  [[ "$output" =~ "disable" ]]
  [[ "$output" =~ "status" ]]
  [[ "$output" =~ "auto-disable" ]]
  [[ "$output" =~ "check-ip" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: show_usage mentions CLUSTER_UPDATE_TIMEOUT" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_usage")
  run bash -c "
    source '$FUNC_FILE'
    show_usage
  "
  [[ "$output" =~ "CLUSTER_UPDATE_TIMEOUT" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: show_usage includes security best practice note" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_usage")
  run bash -c "
    source '$FUNC_FILE'
    show_usage
  "
  [[ "$output" =~ "Security Best Practice" ]]
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

@test "UNIT: get_aws_region rejects malformed region" {
  FUNC_FILE=$(extract_function "$SCRIPT" "get_aws_region")
  run bash -c "
    BLUE='' NC='' YELLOW=''
    TERRAFORM_DIR='/nonexistent/path'
    AWS_REGION='INVALID'
    source '$FUNC_FILE'
    get_aws_region
    echo \"\$AWS_REGION\"
  "
  [[ "$output" =~ "us-west-2" ]]
  rm -f "$FUNC_FILE"
}

# ── UNIT: show_usage depth ──────────────────────────────────────────────────

@test "UNIT: show_usage documents enable subcommand" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_usage")
  run bash -c "
    source '$FUNC_FILE'
    show_usage
  "
  [[ "$output" =~ "enable" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: show_usage documents disable subcommand" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_usage")
  run bash -c "
    source '$FUNC_FILE'
    show_usage
  "
  [[ "$output" =~ "disable" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: show_usage documents status subcommand" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_usage")
  run bash -c "
    source '$FUNC_FILE'
    show_usage
  "
  [[ "$output" =~ "status" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: get_aws_region accepts eu-central-1" {
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
