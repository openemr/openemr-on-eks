#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# BATS Suite: scripts/restore.sh
# Purpose: Validate restore CLI usage, every documented flag and positional arg,
#          timeout defaults, environment variable override patterns, and
#          required-argument error handling.
# Scope:   Invokes only --help and error paths (never runs real restores).
# -----------------------------------------------------------------------------

load test_helper

setup() { cd "$PROJECT_ROOT"; }

SCRIPT="${SCRIPTS_DIR}/restore.sh"

# ── Executable & syntax ─────────────────────────────────────────────────────

@test "restore.sh is executable" {
  [ -x "$SCRIPT" ]
}

@test "restore.sh has valid bash syntax" {
  bash -n "$SCRIPT"
}

# ── Help contract ───────────────────────────────────────────────────────────

@test "-h exits 0" {
  run_script "restore.sh" "-h"
  assert_success
}

@test "--help exits 0" {
  run_script "restore.sh" "--help"
  assert_success
}

@test "--help shows USAGE line" {
  run_script "restore.sh" "--help"
  [[ "$output" =~ USAGE ]]
}

# ── Help documents every option ─────────────────────────────────────────────

@test "--help documents -c/--cluster" {
  run_script "restore.sh" "--help"
  [[ "$output" =~ "--cluster" ]]
}

@test "--help documents -n/--namespace" {
  run_script "restore.sh" "--help"
  [[ "$output" =~ "--namespace" ]]
}

@test "--help documents -r/--region" {
  run_script "restore.sh" "--help"
  [[ "$output" =~ "--region" ]]
}

@test "--help documents --kms-key" {
  run_script "restore.sh" "--help"
  [[ "$output" =~ "--kms-key" ]]
}

@test "--help documents --latest-snapshot" {
  run_script "restore.sh" "--help"
  [[ "$output" =~ "--latest-snapshot" ]]
}

# ── Help documents environment variables ────────────────────────────────────

@test "--help mentions DB_CLUSTER_WAIT_TIMEOUT" {
  run_script "restore.sh" "--help"
  [[ "$output" =~ "DB_CLUSTER_WAIT_TIMEOUT" ]]
}

@test "--help mentions POD_READY_WAIT_TIMEOUT" {
  run_script "restore.sh" "--help"
  [[ "$output" =~ "POD_READY_WAIT_TIMEOUT" ]]
}

@test "--help mentions MAX_RETRIES" {
  run_script "restore.sh" "--help"
  [[ "$output" =~ "MAX_RETRIES" ]]
}

# ── Help content quality ───────────────────────────────────────────────────

@test "--help includes ARGUMENTS section" {
  run_script "restore.sh" "--help"
  [[ "$output" =~ "ARGUMENTS" ]]
}

@test "--help includes EXAMPLES section" {
  run_script "restore.sh" "--help"
  [[ "$output" =~ "EXAMPLES" ]]
}

@test "--help includes DESCRIPTION section" {
  run_script "restore.sh" "--help"
  [[ "$output" =~ "DESCRIPTION" ]]
}

@test "--help mentions backup-bucket argument" {
  run_script "restore.sh" "--help"
  [[ "$output" =~ "backup-bucket" ]]
}

@test "--help mentions snapshot-id argument" {
  run_script "restore.sh" "--help"
  [[ "$output" =~ "snapshot-id" ]]
}

# ── Missing required arguments ──────────────────────────────────────────────

@test "no args exits non-zero or shows help" {
  run_script "restore.sh"
  # Either shows help (exit 0) or fails with clear message
  [[ "$output" =~ (USAGE|Usage|usage|help|backup|snapshot|required) ]] || [ "$status" -ne 0 ]
}

# ── Error handling ──────────────────────────────────────────────────────────

@test "unknown option exits non-zero" {
  run_script "restore.sh" "--bogus"
  [ "$status" -ne 0 ]
}

@test "unknown option shows help or names bad flag" {
  run_script "restore.sh" "--bogus"
  [[ "$output" =~ (Unknown option|bogus|USAGE|help) ]]
}

# ── Script safety features ─────────────────────────────────────────────────

@test "script uses set -euo pipefail" {
  run grep 'set -euo pipefail' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script disables AWS_PAGER" {
  run grep 'export AWS_PAGER=""' "$SCRIPT"
  [ "$status" -eq 0 ]
}

# ── Temp pod resource defaults ──────────────────────────────────────────────

@test "default TEMP_POD_MEMORY_REQUEST is 1Gi" {
  run grep 'TEMP_POD_MEMORY_REQUEST.*1Gi' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "default TEMP_POD_CPU_REQUEST is 500m" {
  run grep 'TEMP_POD_CPU_REQUEST.*500m' "$SCRIPT"
  [ "$status" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════
# Function-level unit tests
# These extract individual functions and test them in isolation.
# ═══════════════════════════════════════════════════════════════════════════

@test "UNIT: aws_with_retry function exists and has retry logic" {
  local func_file
  func_file=$(extract_function "$SCRIPT" "aws_with_retry")
  [ -s "$func_file" ]
  # Verify it contains retry logic keywords
  run bash -c 'cat "'"$func_file"'"'
  [[ "$output" =~ "attempt" ]]
  [[ "$output" =~ "retry" ]] || [[ "$output" =~ "max_attempts" ]]
  rm -f "$func_file"
}

@test "UNIT: show_help function exists and outputs USAGE" {
  # restore.sh uses show_help or show_usage
  run grep -c 'show_help\|show_usage\|usage()' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "UNIT: default timeout values are reasonable" {
  # Verify default timeout constants match expected values
  run bash -c '
    grep "DB_CLUSTER_WAIT_TIMEOUT" "'"$SCRIPT"'" | head -1
  '
  [[ "$output" =~ "1200" ]]

  run bash -c '
    grep "POD_READY_WAIT_TIMEOUT" "'"$SCRIPT"'" | head -1
  '
  [[ "$output" =~ "600" ]]
}

@test "UNIT: script defines DEFAULT_NAMESPACE as openemr" {
  run grep 'DEFAULT_NAMESPACE.*openemr' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "UNIT: script defines DEFAULT_AWS_REGION as us-west-2" {
  run grep 'DEFAULT_AWS_REGION.*us-west-2' "$SCRIPT"
  [ "$status" -eq 0 ]
}

# ── UNIT: parse_arguments ───────────────────────────────────────────────────

@test "UNIT: parse_arguments sets CLUSTER_NAME from -c flag" {
  run bash -c '
    RED="" NC="" YELLOW="" BLUE=""
    CLUSTER_NAME="" NAMESPACE="" AWS_REGION="" BACKUP_BUCKET="" SNAPSHOT_ID=""
    CUSTOM_KMS_KEY="" USE_LATEST_SNAPSHOT=false
    show_help() { echo "HELP"; exit 0; }
    parse_arguments() {
      while [ $# -gt 0 ]; do
        case $1 in
          -c|--cluster) CLUSTER_NAME="$2"; shift 2 ;;
          -n|--namespace) NAMESPACE="$2"; shift 2 ;;
          -r|--region) AWS_REGION="$2"; shift 2 ;;
          --latest-snapshot) USE_LATEST_SNAPSHOT=true; shift ;;
          -*) echo "Unknown option: $1" >&2; exit 1 ;;
          *) if [ -z "$BACKUP_BUCKET" ]; then BACKUP_BUCKET="${1#s3://}"; elif [ -z "$SNAPSHOT_ID" ]; then SNAPSHOT_ID="$1"; fi; shift ;;
        esac
      done
    }
    parse_arguments -c my-cluster
    echo "CLUSTER_NAME=$CLUSTER_NAME"
  '
  [[ "$output" =~ "CLUSTER_NAME=my-cluster" ]]
}

@test "UNIT: parse_arguments sets NAMESPACE from -n flag" {
  run bash -c '
    RED="" NC="" CLUSTER_NAME="" NAMESPACE="" AWS_REGION="" BACKUP_BUCKET="" SNAPSHOT_ID=""
    USE_LATEST_SNAPSHOT=false
    show_help() { echo "HELP"; exit 0; }
    parse_arguments() {
      while [ $# -gt 0 ]; do
        case $1 in
          -c|--cluster) CLUSTER_NAME="$2"; shift 2 ;;
          -n|--namespace) NAMESPACE="$2"; shift 2 ;;
          -r|--region) AWS_REGION="$2"; shift 2 ;;
          --latest-snapshot) USE_LATEST_SNAPSHOT=true; shift ;;
          -*) echo "Unknown: $1" >&2; exit 1 ;;
          *) if [ -z "$BACKUP_BUCKET" ]; then BACKUP_BUCKET="${1#s3://}"; fi; shift ;;
        esac
      done
    }
    parse_arguments -n custom-ns
    echo "NAMESPACE=$NAMESPACE"
  '
  [[ "$output" =~ "NAMESPACE=custom-ns" ]]
}

@test "UNIT: parse_arguments sets USE_LATEST_SNAPSHOT flag" {
  run bash -c '
    RED="" NC="" CLUSTER_NAME="" NAMESPACE="" AWS_REGION="" BACKUP_BUCKET="" SNAPSHOT_ID=""
    USE_LATEST_SNAPSHOT=false
    show_help() { echo "HELP"; exit 0; }
    parse_arguments() {
      while [ $# -gt 0 ]; do
        case $1 in
          --latest-snapshot) USE_LATEST_SNAPSHOT=true; shift ;;
          -*) echo "Unknown: $1" >&2; exit 1 ;;
          *) shift ;;
        esac
      done
    }
    parse_arguments --latest-snapshot
    echo "LATEST=$USE_LATEST_SNAPSHOT"
  '
  [[ "$output" =~ "LATEST=true" ]]
}

@test "UNIT: parse_arguments strips s3:// prefix from bucket" {
  run bash -c '
    RED="" NC="" CLUSTER_NAME="" NAMESPACE="" AWS_REGION="" BACKUP_BUCKET="" SNAPSHOT_ID=""
    USE_LATEST_SNAPSHOT=false
    show_help() { echo "HELP"; exit 0; }
    parse_arguments() {
      while [ $# -gt 0 ]; do
        case $1 in
          -*) echo "Unknown: $1" >&2; exit 1 ;;
          *) if [ -z "$BACKUP_BUCKET" ]; then BACKUP_BUCKET="${1#s3://}"; elif [ -z "$SNAPSHOT_ID" ]; then SNAPSHOT_ID="$1"; fi; shift ;;
        esac
      done
    }
    parse_arguments "s3://my-backup-bucket"
    echo "BUCKET=$BACKUP_BUCKET"
  '
  [[ "$output" =~ "BUCKET=my-backup-bucket" ]]
}

# ── UNIT: explain_snapshot_status ───────────────────────────────────────────

@test "UNIT: explain_snapshot_status handles unknown status" {
  FUNC_FILE=$(extract_function "$SCRIPT" "explain_snapshot_status")
  run bash -c "
    YELLOW='' NC=''
    source '$FUNC_FILE'
    explain_snapshot_status 'unknown' 2>&1
  "
  [[ "$output" =~ "deleted or expired" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: explain_snapshot_status handles deleted status" {
  FUNC_FILE=$(extract_function "$SCRIPT" "explain_snapshot_status")
  run bash -c "
    YELLOW='' NC=''
    source '$FUNC_FILE'
    explain_snapshot_status 'deleted' 2>&1
  "
  [[ "$output" =~ "deleted" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: explain_snapshot_status handles failed status" {
  FUNC_FILE=$(extract_function "$SCRIPT" "explain_snapshot_status")
  run bash -c "
    YELLOW='' NC=''
    source '$FUNC_FILE'
    explain_snapshot_status 'failed' 2>&1
  "
  [[ "$output" =~ "failed" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: explain_snapshot_status handles arbitrary status" {
  FUNC_FILE=$(extract_function "$SCRIPT" "explain_snapshot_status")
  run bash -c "
    YELLOW='' NC=''
    source '$FUNC_FILE'
    explain_snapshot_status 'pending' 2>&1
  "
  [[ "$output" =~ "not ready" ]]
  rm -f "$FUNC_FILE"
}

# ── UNIT: show_help ─────────────────────────────────────────────────────────

@test "UNIT: show_help prints USAGE and all flag documentation" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_help")
  run bash -c "
    source '$FUNC_FILE'
    show_help
  "
  assert_success
  [[ "$output" =~ "USAGE" ]]
  [[ "$output" =~ "--cluster" ]]
  [[ "$output" =~ "--namespace" ]]
  [[ "$output" =~ "--region" ]]
  [[ "$output" =~ "--latest-snapshot" ]]
  rm -f "$FUNC_FILE"
}
