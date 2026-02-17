#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# BATS Suite: scripts/destroy.sh
# Purpose: Validate destroy CLI safety prompts, --help contract, --force flag,
#          prerequisite checking logic, and error handling for unknown options.
# Scope:   Invokes only --help and invalid-option paths (never destroys anything).
# -----------------------------------------------------------------------------

load test_helper

setup() { cd "$PROJECT_ROOT"; }

SCRIPT="${SCRIPTS_DIR}/destroy.sh"

# ── Executable & syntax ─────────────────────────────────────────────────────

@test "destroy.sh is executable" {
  [ -x "$SCRIPT" ]
}

@test "destroy.sh has valid bash syntax" {
  bash -n "$SCRIPT"
}

# ── Help contract ───────────────────────────────────────────────────────────

@test "--help exits 0" {
  run_script "destroy.sh" "--help"
  assert_success
}

@test "-h exits 0" {
  run_script "destroy.sh" "-h"
  assert_success
}

@test "--help shows help content" {
  run_script "destroy.sh" "--help"
  [[ "$output" =~ (Usage|usage|Options|--force) ]]
}

# ── Help documents flags ───────────────────────────────────────────────────

@test "--help documents --force" {
  run_script "destroy.sh" "--help"
  [[ "$output" =~ "--force" ]]
}

@test "--help documents -h/--help" {
  run_script "destroy.sh" "--help"
  [[ "$output" =~ "--help" ]]
}

@test "--help includes warning about destruction" {
  run_script "destroy.sh" "--help"
  [[ "$output" =~ (WARNING|warning|destroy|delete|remove|irreversible) ]]
}

# ── Error handling ──────────────────────────────────────────────────────────

@test "unknown option exits non-zero" {
  run_script "destroy.sh" "--unknown"
  [ "$status" -ne 0 ]
}

@test "unknown option names the bad flag" {
  run_script "destroy.sh" "--badopt"
  [[ "$output" =~ "badopt" ]]
}

@test "unknown option suggests help" {
  run_script "destroy.sh" "--unknown"
  [[ "$output" =~ (help|Usage|usage) ]]
}

# ── Prerequisite function ──────────────────────────────────────────────────

@test "script defines check_prerequisites function" {
  run grep 'check_prerequisites()' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "check_prerequisites checks for terraform" {
  run grep -A20 'check_prerequisites()' "$SCRIPT"
  [[ "$output" =~ terraform ]]
}

@test "check_prerequisites checks for aws cli" {
  run grep -A20 'check_prerequisites()' "$SCRIPT"
  [[ "$output" =~ aws ]]
}

@test "check_prerequisites checks for jq" {
  run grep -A20 'check_prerequisites()' "$SCRIPT"
  [[ "$output" =~ jq ]]
}

# ── Static analysis ────────────────────────────────────────────────────────

@test "FORCE defaults to false" {
  run grep 'FORCE=false' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script defines get_aws_region function" {
  run grep 'get_aws_region()' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "get_aws_region validates region format" {
  run grep -A20 'get_aws_region()' "$SCRIPT"
  [[ "$output" =~ 'a-z.*a-z.*0-9' ]]
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

@test "UNIT: show_help documents --force flag" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_help")
  run bash -c "
    source '$FUNC_FILE'
    show_help
  "
  [[ "$output" =~ "--force" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: show_help includes WARNING" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_help")
  run bash -c "
    source '$FUNC_FILE'
    show_help
  "
  [[ "$output" =~ "WARNING" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: show_help documents what script does and doesn't do" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_help")
  run bash -c "
    source '$FUNC_FILE'
    show_help
  "
  [[ "$output" =~ "WHAT THIS SCRIPT DOES:" ]]
  [[ "$output" =~ "WHAT THIS SCRIPT DOES NOT DO:" ]]
  rm -f "$FUNC_FILE"
}

# ── UNIT: log functions ─────────────────────────────────────────────────────

@test "UNIT: log_info outputs message with info marker" {
  FUNC_FILE=$(extract_function "$SCRIPT" "log_info")
  run bash -c "
    BLUE='' NC=''
    source '$FUNC_FILE'
    log_info 'test message'
  "
  [[ "$output" =~ "test message" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: log_step outputs message" {
  FUNC_FILE=$(extract_function "$SCRIPT" "log_step")
  run bash -c "
    BLUE='' NC=''
    source '$FUNC_FILE'
    log_step 'step message'
  "
  [[ "$output" =~ "step message" ]]
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

@test "UNIT: log_success outputs formatted message" {
  FUNC_FILE=$(extract_function "$SCRIPT" "log_success")
  run bash -c "
    GREEN='' NC=''
    source '$FUNC_FILE'
    log_success 'cleanup complete'
  "
  [[ "$output" =~ "cleanup complete" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: log_warning outputs formatted message" {
  FUNC_FILE=$(extract_function "$SCRIPT" "log_warning")
  run bash -c "
    YELLOW='' NC=''
    source '$FUNC_FILE'
    log_warning 'resource not found'
  "
  [[ "$output" =~ "resource not found" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: log_error outputs formatted message to stderr" {
  FUNC_FILE=$(extract_function "$SCRIPT" "log_error")
  run bash -c "
    RED='' NC=''
    source '$FUNC_FILE'
    log_error 'destroy failed' 2>&1
  "
  [[ "$output" =~ "destroy failed" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: show_help includes EXAMPLES section" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_help")
  run bash -c "
    source '$FUNC_FILE'
    show_help
  "
  [[ "$output" =~ "EXAMPLES" ]]
  rm -f "$FUNC_FILE"
}
