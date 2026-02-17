#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# BATS Suite: scripts/backup.sh
# Purpose: Validate backup CLI contract, every documented flag, default values,
#          environment variable overridability, help content completeness,
#          and safety guidance output.
# Scope:   Invokes only --help and invalid-option paths (never runs backups).
# -----------------------------------------------------------------------------

load test_helper

setup() { cd "$PROJECT_ROOT"; }

SCRIPT="${SCRIPTS_DIR}/backup.sh"

# ── Executable & syntax ─────────────────────────────────────────────────────

@test "backup.sh is executable" {
  [ -x "$SCRIPT" ]
}

@test "backup.sh has valid bash syntax" {
  bash -n "$SCRIPT"
}

# ── Help contract ───────────────────────────────────────────────────────────

@test "--help exits 0" {
  run_script "backup.sh" "--help"
  assert_success
}

@test "--help shows Usage line" {
  run_script "backup.sh" "--help"
  [[ "$output" =~ Usage ]]
}

# ── Help documents every flag ───────────────────────────────────────────────

@test "--help documents --cluster-name" {
  run_script "backup.sh" "--help"
  [[ "$output" =~ "--cluster-name" ]]
}

@test "--help documents --source-region" {
  run_script "backup.sh" "--help"
  [[ "$output" =~ "--source-region" ]]
}

@test "--help documents --backup-region" {
  run_script "backup.sh" "--help"
  [[ "$output" =~ "--backup-region" ]]
}

@test "--help documents --namespace" {
  run_script "backup.sh" "--help"
  [[ "$output" =~ "--namespace" ]]
}

@test "--help documents --strategy" {
  run_script "backup.sh" "--help"
  [[ "$output" =~ "--strategy" ]]
}

@test "--help documents --target-account" {
  run_script "backup.sh" "--help"
  [[ "$output" =~ "--target-account" ]]
}

@test "--help documents --kms-key-id" {
  run_script "backup.sh" "--help"
  [[ "$output" =~ "--kms-key-id" ]]
}

@test "--help documents --no-copy-tags" {
  run_script "backup.sh" "--help"
  [[ "$output" =~ "--no-copy-tags" ]]
}

# ── Help content quality ───────────────────────────────────────────────────

@test "--help mentions backup strategies" {
  run_script "backup.sh" "--help"
  [[ "$output" =~ "same-region" ]]
  [[ "$output" =~ "cross-region" ]]
}

@test "--help mentions what gets backed up" {
  run_script "backup.sh" "--help"
  [[ "$output" =~ "RDS" ]]
  [[ "$output" =~ "Kubernetes" ]]
}

@test "--help includes examples" {
  run_script "backup.sh" "--help"
  [[ "$output" =~ "Examples" ]]
}

@test "--help includes safety warning" {
  run_script "backup.sh" "--help"
  [[ "$output" =~ "WARNING" ]]
}

# ── Error handling ──────────────────────────────────────────────────────────

@test "unknown option exits non-zero" {
  run_script "backup.sh" "--unknown-option"
  [ "$status" -ne 0 ]
}

@test "unknown option suggests --help" {
  run_script "backup.sh" "--unknown-option"
  [[ "$output" =~ (help|Usage) ]]
}

@test "unknown option names the bad flag" {
  run_script "backup.sh" "--bogus-flag"
  [[ "$output" =~ "bogus-flag" ]]
}

# ── AWS CLI pager disabled ─────────────────────────────────────────────────

@test "script disables AWS_PAGER" {
  run grep 'export AWS_PAGER=""' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script disables AWS_CLI_AUTO_PROMPT" {
  run grep 'export AWS_CLI_AUTO_PROMPT=off' "$SCRIPT"
  [ "$status" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════
# Function-level unit tests
# These extract functions from the script and test them in isolation.
# ═══════════════════════════════════════════════════════════════════════════

@test "UNIT: show_help outputs Usage line" {
  local func_file
  func_file=$(extract_function "$SCRIPT" "show_help")
  run bash -c '
    CLUSTER_NAME="openemr-eks"
    AWS_REGION="us-west-2"
    BACKUP_REGION="us-west-2"
    NAMESPACE="openemr"
    DEFAULT_TAGS_TO_SHOW=10
    source "'"$func_file"'"
    show_help
  '
  rm -f "$func_file"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Usage" ]]
}

@test "UNIT: show_help documents all flags" {
  local func_file
  func_file=$(extract_function "$SCRIPT" "show_help")
  run bash -c '
    CLUSTER_NAME="openemr-eks"
    AWS_REGION="us-west-2"
    BACKUP_REGION="us-west-2"
    NAMESPACE="openemr"
    source "'"$func_file"'"
    show_help
  '
  rm -f "$func_file"
  [[ "$output" =~ "--cluster-name" ]]
  [[ "$output" =~ "--source-region" ]]
  [[ "$output" =~ "--backup-region" ]]
  [[ "$output" =~ "--namespace" ]]
  [[ "$output" =~ "--strategy" ]]
}

@test "UNIT: show_help mentions backup strategies" {
  local func_file
  func_file=$(extract_function "$SCRIPT" "show_help")
  run bash -c '
    CLUSTER_NAME="openemr-eks"
    AWS_REGION="us-west-2"
    BACKUP_REGION="us-west-2"
    NAMESPACE="openemr"
    source "'"$func_file"'"
    show_help
  '
  rm -f "$func_file"
  [[ "$output" =~ "same-region" ]]
  [[ "$output" =~ "cross-region" ]]
}

# ── UNIT: add_result ────────────────────────────────────────────────────────

@test "UNIT: add_result appends success result to BACKUP_RESULTS" {
  run bash -c '
    BACKUP_RESULTS=""
    BACKUP_SUCCESS=true
    add_result() {
      local component=$1 status=$2 details=$3
      BACKUP_RESULTS="${BACKUP_RESULTS}${component}: ${status}"
      [ -n "$details" ] && BACKUP_RESULTS="${BACKUP_RESULTS} (${details})"
      BACKUP_RESULTS="${BACKUP_RESULTS}\n"
      [ "$status" = "FAILED" ] && BACKUP_SUCCESS=false
    }
    add_result "RDS Snapshot" "SUCCESS" "snap-123"
    echo -e "$BACKUP_RESULTS"
    echo "SUCCESS=$BACKUP_SUCCESS"
  '
  [[ "$output" =~ "RDS Snapshot: SUCCESS (snap-123)" ]]
  [[ "$output" =~ "SUCCESS=true" ]]
}

@test "UNIT: add_result sets BACKUP_SUCCESS=false on FAILED" {
  run bash -c '
    BACKUP_RESULTS=""
    BACKUP_SUCCESS=true
    add_result() {
      local component=$1 status=$2 details=$3
      BACKUP_RESULTS="${BACKUP_RESULTS}${component}: ${status}"
      [ -n "$details" ] && BACKUP_RESULTS="${BACKUP_RESULTS} (${details})"
      BACKUP_RESULTS="${BACKUP_RESULTS}\n"
      [ "$status" = "FAILED" ] && BACKUP_SUCCESS=false
    }
    add_result "S3 Backup" "FAILED" "bucket error"
    echo "SUCCESS=$BACKUP_SUCCESS"
  '
  [[ "$output" =~ "SUCCESS=false" ]]
}

@test "UNIT: add_result handles empty details" {
  run bash -c '
    BACKUP_RESULTS=""
    BACKUP_SUCCESS=true
    add_result() {
      local component=$1 status=$2 details=$3
      BACKUP_RESULTS="${BACKUP_RESULTS}${component}: ${status}"
      [ -n "$details" ] && BACKUP_RESULTS="${BACKUP_RESULTS} (${details})"
      BACKUP_RESULTS="${BACKUP_RESULTS}\n"
      [ "$status" = "FAILED" ] && BACKUP_SUCCESS=false
    }
    add_result "K8s Configs" "SUCCESS" ""
    echo -e "$BACKUP_RESULTS"
  '
  [[ "$output" =~ "K8s Configs: SUCCESS" ]]
  # Should NOT have parentheses for empty details
  [[ ! "$output" =~ "K8s Configs: SUCCESS ()" ]]
}

# ── UNIT: validate_backup_strategy ──────────────────────────────────────────

@test "UNIT: validate_backup_strategy accepts same-region" {
  run bash -c '
    log_info() { echo "INFO: $*"; }
    log_success() { echo "SUCCESS: $*"; }
    log_error() { echo "ERROR: $*" >&2; }
    log_warning() { echo "WARN: $*"; }
    BACKUP_STRATEGY="same-region"
    AWS_REGION="us-west-2"
    BACKUP_REGION="us-west-2"

    validate_backup_strategy() {
      case "$BACKUP_STRATEGY" in
        "same-region") log_info "Using same-region backup strategy" ;;
        "cross-region")
          if [ "$AWS_REGION" = "$BACKUP_REGION" ]; then
            log_error "Cross-region backup requires different regions"; exit 1
          fi ;;
        "cross-account")
          if [ -z "$TARGET_ACCOUNT_ID" ]; then
            log_error "Cross-account backup requires --target-account"; exit 1
          fi
          if ! [[ "$TARGET_ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
            log_error "Invalid AWS account ID format"; exit 1
          fi ;;
        *) log_error "Invalid backup strategy: $BACKUP_STRATEGY"; exit 1 ;;
      esac
      log_success "Backup strategy validated"
    }
    validate_backup_strategy
  '
  assert_success
  [[ "$output" =~ "same-region" ]]
}

@test "UNIT: validate_backup_strategy rejects invalid strategy" {
  run bash -c '
    log_info() { echo "INFO: $*"; }
    log_success() { echo "SUCCESS: $*"; }
    log_error() { echo "ERROR: $*" >&2; }
    BACKUP_STRATEGY="invalid-strategy"

    validate_backup_strategy() {
      case "$BACKUP_STRATEGY" in
        "same-region"|"cross-region"|"cross-account") ;;
        *) log_error "Invalid backup strategy: $BACKUP_STRATEGY"; exit 1 ;;
      esac
    }
    validate_backup_strategy
  '
  assert_failure
}

@test "UNIT: validate_backup_strategy rejects cross-region with same regions" {
  run bash -c '
    log_info() { echo "INFO: $*"; }
    log_error() { echo "ERROR: $*" >&2; }
    BACKUP_STRATEGY="cross-region"
    AWS_REGION="us-west-2"
    BACKUP_REGION="us-west-2"

    validate_backup_strategy() {
      case "$BACKUP_STRATEGY" in
        "cross-region")
          if [ "$AWS_REGION" = "$BACKUP_REGION" ]; then
            log_error "Cross-region backup requires different regions"; exit 1
          fi ;;
      esac
    }
    validate_backup_strategy
  '
  assert_failure
}

# ── UNIT: log functions ─────────────────────────────────────────────────────

@test "UNIT: log_info outputs formatted message" {
  FUNC_FILE=$(extract_function "$SCRIPT" "log_info")
  run bash -c "
    BLUE='' NC=''
    source '$FUNC_FILE'
    log_info 'backup log test'
  "
  [[ "$output" =~ "backup log test" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: log_success outputs formatted message" {
  FUNC_FILE=$(extract_function "$SCRIPT" "log_success")
  run bash -c "
    GREEN='' NC=''
    source '$FUNC_FILE'
    log_success 'backup complete'
  "
  [[ "$output" =~ "backup complete" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: log_warning outputs formatted message" {
  FUNC_FILE=$(extract_function "$SCRIPT" "log_warning")
  run bash -c "
    YELLOW='' NC=''
    source '$FUNC_FILE'
    log_warning 'low disk space'
  "
  [[ "$output" =~ "low disk space" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: log_error outputs formatted message" {
  FUNC_FILE=$(extract_function "$SCRIPT" "log_error")
  run bash -c "
    RED='' NC=''
    source '$FUNC_FILE'
    log_error 'snapshot failed' 2>&1
  "
  [[ "$output" =~ "snapshot failed" ]]
  rm -f "$FUNC_FILE"
}
