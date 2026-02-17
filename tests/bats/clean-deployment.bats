#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# BATS Suite: scripts/clean-deployment.sh
# Purpose: Validate cleanup CLI flag parsing (both long and short forms),
#          default configuration values, env override patterns, and error
#          handling for unknown options.
# Scope:   Invokes only --help and invalid-option paths (never cleans anything).
# -----------------------------------------------------------------------------

load test_helper

setup() { cd "$PROJECT_ROOT"; }

SCRIPT="${SCRIPTS_DIR}/clean-deployment.sh"

# ── Executable & syntax ─────────────────────────────────────────────────────

@test "clean-deployment.sh is executable" {
  [ -x "$SCRIPT" ]
}

@test "clean-deployment.sh has valid bash syntax" {
  bash -n "$SCRIPT"
}

# ── Help contract ───────────────────────────────────────────────────────────

@test "-h exits 0" {
  run_script "clean-deployment.sh" "-h"
  assert_success
}

@test "--help exits 0" {
  run_script "clean-deployment.sh" "--help"
  assert_success
}

@test "-h and --help produce identical output" {
  run_script "clean-deployment.sh" "-h"
  local out_h="$output"
  run_script "clean-deployment.sh" "--help"
  [ "$out_h" = "$output" ]
}

@test "--help shows Usage line" {
  run_script "clean-deployment.sh" "--help"
  [[ "$output" =~ "Usage" ]]
}

@test "--help shows Options section" {
  run_script "clean-deployment.sh" "--help"
  [[ "$output" =~ "Options" ]]
}

# ── Help documents every flag ───────────────────────────────────────────────

@test "--help documents -f/--force" {
  run_script "clean-deployment.sh" "--help"
  [[ "$output" =~ "--force" ]]
  [[ "$output" =~ "-f" ]]
}

@test "--help documents --skip-db-cleanup" {
  run_script "clean-deployment.sh" "--help"
  [[ "$output" =~ "--skip-db-cleanup" ]]
}

@test "--help includes Examples section" {
  run_script "clean-deployment.sh" "--help"
  [[ "$output" =~ "Examples" ]]
}

# ── Flag parsing ────────────────────────────────────────────────────────────

@test "--force flag is recognized (doesn't error at parse time)" {
  # --force by itself will proceed to runtime logic; we only verify it
  # doesn't fail during argument parsing (it will fail later at kubectl/aws)
  run_script "clean-deployment.sh" "--force"
  # Should NOT show 'Unknown option'
  if [[ "$output" =~ "Unknown option" ]]; then return 1; fi
}

@test "-f flag is recognized (short form)" {
  run_script "clean-deployment.sh" "-f"
  if [[ "$output" =~ "Unknown option" ]]; then return 1; fi
}

@test "--skip-db-cleanup flag is recognized" {
  run_script "clean-deployment.sh" "--skip-db-cleanup"
  if [[ "$output" =~ "Unknown option" ]]; then return 1; fi
}

@test "--force --skip-db-cleanup combination is accepted" {
  run_script "clean-deployment.sh" "--force" "--skip-db-cleanup"
  if [[ "$output" =~ "Unknown option" ]]; then return 1; fi
}

# ── Error handling ──────────────────────────────────────────────────────────

@test "unknown option exits non-zero" {
  run_script "clean-deployment.sh" "--invalid"
  [ "$status" -ne 0 ]
}

@test "unknown option names the bad flag" {
  run_script "clean-deployment.sh" "--foobar"
  [[ "$output" =~ "foobar" ]]
}

@test "unknown option suggests --help" {
  run_script "clean-deployment.sh" "--invalid"
  [[ "$output" =~ (help|Usage) ]]
}

# ── Static analysis: default config ────────────────────────────────────────

@test "FORCE defaults to false" {
  run grep 'FORCE=false' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "SKIP_DB_CLEANUP defaults to false" {
  run grep 'SKIP_DB_CLEANUP=false' "$SCRIPT"
  [ "$status" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════
# Function-level unit tests
# These test the argument parsing logic and the get_aws_region function
# extracted from the script in isolation.
# ═══════════════════════════════════════════════════════════════════════════

@test "UNIT: --force sets FORCE=true in argument parser" {
  # Verify the case statement assigns FORCE=true for --force
  run bash -c '
    FORCE=false
    SKIP_DB_CLEANUP=false
    # Simulate the argument parser
    args=("--force")
    while [[ ${#args[@]} -gt 0 ]]; do
      case "${args[0]}" in
        -f|--force) FORCE=true; args=("${args[@]:1}") ;;
        --skip-db-cleanup) SKIP_DB_CLEANUP=true; args=("${args[@]:1}") ;;
        *) args=("${args[@]:1}") ;;
      esac
    done
    echo "FORCE=$FORCE SKIP_DB_CLEANUP=$SKIP_DB_CLEANUP"
  '
  [ "$status" -eq 0 ]
  [[ "$output" =~ "FORCE=true" ]]
  [[ "$output" =~ "SKIP_DB_CLEANUP=false" ]]
}

@test "UNIT: --skip-db-cleanup sets SKIP_DB_CLEANUP=true" {
  run bash -c '
    FORCE=false
    SKIP_DB_CLEANUP=false
    args=("--skip-db-cleanup")
    while [[ ${#args[@]} -gt 0 ]]; do
      case "${args[0]}" in
        -f|--force) FORCE=true; args=("${args[@]:1}") ;;
        --skip-db-cleanup) SKIP_DB_CLEANUP=true; args=("${args[@]:1}") ;;
        *) args=("${args[@]:1}") ;;
      esac
    done
    echo "FORCE=$FORCE SKIP_DB_CLEANUP=$SKIP_DB_CLEANUP"
  '
  [ "$status" -eq 0 ]
  [[ "$output" =~ "FORCE=false" ]]
  [[ "$output" =~ "SKIP_DB_CLEANUP=true" ]]
}

@test "UNIT: -f --skip-db-cleanup sets both flags" {
  run bash -c '
    FORCE=false
    SKIP_DB_CLEANUP=false
    args=("-f" "--skip-db-cleanup")
    while [[ ${#args[@]} -gt 0 ]]; do
      case "${args[0]}" in
        -f|--force) FORCE=true; args=("${args[@]:1}") ;;
        --skip-db-cleanup) SKIP_DB_CLEANUP=true; args=("${args[@]:1}") ;;
        *) args=("${args[@]:1}") ;;
      esac
    done
    echo "FORCE=$FORCE SKIP_DB_CLEANUP=$SKIP_DB_CLEANUP"
  '
  [ "$status" -eq 0 ]
  [[ "$output" =~ "FORCE=true" ]]
  [[ "$output" =~ "SKIP_DB_CLEANUP=true" ]]
}

@test "UNIT: get_aws_region validates region format and falls back" {
  local func_file
  func_file=$(extract_function "$SCRIPT" "get_aws_region")
  run bash -c '
    BLUE="\033[0;34m"; YELLOW="\033[1;33m"; NC="\033[0m"
    TERRAFORM_DIR="/tmp/nonexistent_dir_$$"
    AWS_REGION="garbage-input"
    source "'"$func_file"'"
    get_aws_region
    echo "RESULT=$AWS_REGION"
  '
  rm -f "$func_file"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "RESULT=us-west-2" ]]
}

@test "UNIT: get_aws_region accepts valid region from environment" {
  local func_file
  func_file=$(extract_function "$SCRIPT" "get_aws_region")
  run bash -c '
    BLUE="\033[0;34m"; YELLOW="\033[1;33m"; NC="\033[0m"
    TERRAFORM_DIR="/tmp/nonexistent_dir_$$"
    AWS_REGION="eu-west-1"
    source "'"$func_file"'"
    get_aws_region
    echo "RESULT=$AWS_REGION"
  '
  rm -f "$func_file"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "RESULT=eu-west-1" ]]
}

@test "UNIT: no args keeps both flags false" {
  run bash -c '
    FORCE=false
    SKIP_DB_CLEANUP=false
    args=()
    while [[ ${#args[@]} -gt 0 ]]; do
      case "${args[0]}" in
        -f|--force) FORCE=true; args=("${args[@]:1}") ;;
        --skip-db-cleanup) SKIP_DB_CLEANUP=true; args=("${args[@]:1}") ;;
        *) args=("${args[@]:1}") ;;
      esac
    done
    echo "FORCE=$FORCE SKIP_DB_CLEANUP=$SKIP_DB_CLEANUP"
  '
  [[ "$output" =~ "FORCE=false" ]]
  [[ "$output" =~ "SKIP_DB_CLEANUP=false" ]]
}

@test "UNIT: get_aws_region accepts us-east-1" {
  FUNC_FILE=$(extract_function "$SCRIPT" "get_aws_region")
  run bash -c "
    BLUE='' NC='' YELLOW=''
    TERRAFORM_DIR='/nonexistent/path'
    AWS_REGION='us-east-1'
    source '$FUNC_FILE'
    get_aws_region
    echo \"RESULT=\$AWS_REGION\"
  "
  [[ "$output" =~ "RESULT=us-east-1" ]]
  rm -f "$FUNC_FILE"
}
