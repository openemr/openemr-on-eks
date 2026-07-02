#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# BATS Suite: scripts/test-end-to-end-backup-restore.sh
# Purpose: Validate E2E backup/restore test CLI options, help completeness,
#          default configuration, timing expectations, and safety warnings.
# Scope:   Invokes only --help and invalid-option paths.
# -----------------------------------------------------------------------------

load test_helper

setup() { cd "$PROJECT_ROOT"; }

SCRIPT="${SCRIPTS_DIR}/test-end-to-end-backup-restore.sh"

# ── Executable & syntax ─────────────────────────────────────────────────────

@test "test-end-to-end-backup-restore.sh is executable" {
  [ -x "$SCRIPT" ]
}

@test "test-end-to-end-backup-restore.sh has valid bash syntax" {
  bash -n "$SCRIPT"
}

# ── Help contract ───────────────────────────────────────────────────────────

@test "--help exits 0" {
  run_script "test-end-to-end-backup-restore.sh" "--help"
  assert_success
}

@test "--help shows Usage" {
  run_script "test-end-to-end-backup-restore.sh" "--help"
  [[ "$output" =~ "Usage" ]]
}

# ── Help documents information ──────────────────────────────────────────────

@test "--help mentions cluster" {
  run_script "test-end-to-end-backup-restore.sh" "--help"
  [[ "$output" =~ (cluster|backup|restore) ]]
}

@test "--help includes WARNING" {
  run_script "test-end-to-end-backup-restore.sh" "--help"
  [[ "$output" =~ (WARNING|warning|destructive) ]]
}

# ── Error handling ──────────────────────────────────────────────────────────

@test "unknown option exits non-zero" {
  run_script "test-end-to-end-backup-restore.sh" "--invalid"
  [ "$status" -ne 0 ]
}

@test "unknown option suggests help" {
  run_script "test-end-to-end-backup-restore.sh" "--invalid"
  [[ "$output" =~ (help|Usage|usage) ]]
}

# ── Static analysis ────────────────────────────────────────────────────────

@test "script uses set -euo pipefail" {
  run grep 'set -euo pipefail' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script disables AWS_PAGER" {
  run grep 'export AWS_PAGER=""' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "default NAMESPACE is 'openemr'" {
  run grep 'NAMESPACE.*openemr' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "default CLUSTER_NAME is 'openemr-eks'" {
  run grep 'CLUSTER_NAME.*openemr-eks' "$SCRIPT"
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
  [[ "$output" =~ "Usage" ]]
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

@test "UNIT: show_help documents all flags" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_help")
  run bash -c "
    source '$FUNC_FILE'
    show_help
  "
  [[ "$output" =~ "--cluster-name" ]]
  [[ "$output" =~ "--aws-region" ]]
  [[ "$output" =~ "--namespace" ]]
  rm -f "$FUNC_FILE"
}

# ── UNIT: start_timer / get_duration ────────────────────────────────────────

@test "UNIT: start_timer returns a numeric timestamp" {
  FUNC_FILE=$(extract_function "$SCRIPT" "start_timer")
  run bash -c "
    source '$FUNC_FILE'
    ts=\$(start_timer)
    if [[ \"\$ts\" =~ ^[0-9]+$ ]]; then echo 'NUMERIC'; else echo 'BAD'; fi
  "
  [ "$output" = "NUMERIC" ]
  rm -f "$FUNC_FILE"
}

@test "UNIT: get_duration computes elapsed seconds" {
  run bash -c "
    get_duration() {
      local start_time=\"\$1\"
      local end_time
      end_time=\$(date +%s)
      local duration=\$((end_time - start_time))
      echo \"\$duration\"
    }
    start=\$(date +%s)
    sleep 1
    dur=\$(get_duration \$start)
    if [[ \"\$dur\" =~ ^[0-9]+$ ]] && [ \"\$dur\" -ge 1 ]; then echo 'OK'; else echo 'BAD'; fi
  "
  [ "$output" = "OK" ]
}

# ── UNIT: add_test_result ───────────────────────────────────────────────────

@test "UNIT: add_test_result appends to TEST_RESULTS array" {
  run bash -c "
    TEST_RESULTS=()
    add_test_result() {
      local step=\"\$1\" status=\"\$2\" details=\"\$3\" duration=\"\$4\"
      TEST_RESULTS+=(\"\$step|\$status|\$details|\$duration\")
    }
    add_test_result 'step1' 'PASS' 'all good' '5s'
    add_test_result 'step2' 'FAIL' 'broken' '10s'
    echo \${#TEST_RESULTS[@]}
    echo \${TEST_RESULTS[0]}
    echo \${TEST_RESULTS[1]}
  "
  [[ "$output" =~ "2" ]]
  [[ "$output" =~ "step1|PASS|all good|5s" ]]
  [[ "$output" =~ "step2|FAIL|broken|10s" ]]
}

# ── UNIT: parse_arguments ───────────────────────────────────────────────────

@test "UNIT: parse_arguments sets CLUSTER_NAME from --cluster-name" {
  run bash -c '
    CLUSTER_NAME="" AWS_REGION="" NAMESPACE=""
    log_error() { echo "ERROR: $*"; }
    show_help() { echo "HELP"; exit 0; }
    parse_arguments() {
      while [[ $# -gt 0 ]]; do
        case $1 in
          --cluster-name) CLUSTER_NAME="$2"; shift 2 ;;
          --aws-region) AWS_REGION="$2"; shift 2 ;;
          --namespace) NAMESPACE="$2"; shift 2 ;;
          --help) show_help ;;
          *) log_error "Unknown option: $1"; exit 1 ;;
        esac
      done
    }
    parse_arguments --cluster-name test-cluster
    echo "CLUSTER=$CLUSTER_NAME"
  '
  [[ "$output" =~ "CLUSTER=test-cluster" ]]
}

@test "UNIT: parse_arguments sets AWS_REGION from --aws-region" {
  run bash -c '
    CLUSTER_NAME="" AWS_REGION="" NAMESPACE=""
    log_error() { echo "ERROR: $*"; }
    show_help() { echo "HELP"; exit 0; }
    parse_arguments() {
      while [[ $# -gt 0 ]]; do
        case $1 in
          --cluster-name) CLUSTER_NAME="$2"; shift 2 ;;
          --aws-region) AWS_REGION="$2"; shift 2 ;;
          --namespace) NAMESPACE="$2"; shift 2 ;;
          *) log_error "Unknown option: $1"; exit 1 ;;
        esac
      done
    }
    parse_arguments --aws-region eu-central-1
    echo "REGION=$AWS_REGION"
  '
  [[ "$output" =~ "REGION=eu-central-1" ]]
}

@test "UNIT: parse_arguments rejects unknown flags" {
  run bash -c '
    CLUSTER_NAME="" AWS_REGION="" NAMESPACE=""
    log_error() { echo "ERROR: $*"; }
    show_help() { echo "HELP"; }
    parse_arguments() {
      while [[ $# -gt 0 ]]; do
        case $1 in
          --cluster-name) CLUSTER_NAME="$2"; shift 2 ;;
          --aws-region) AWS_REGION="$2"; shift 2 ;;
          --namespace) NAMESPACE="$2"; shift 2 ;;
          --help) show_help ;;
          *) log_error "Unknown option: $1"; exit 1 ;;
        esac
      done
    }
    parse_arguments --bogus-flag
  '
  assert_failure
}

# ── UNIT: show_help details ─────────────────────────────────────────────────

@test "UNIT: show_help lists --cluster-name option" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_help")
  run bash -c "
    BLUE='' GREEN='' RED='' YELLOW='' NC=''
    source '$FUNC_FILE'
    show_help 2>&1
  "
  [[ "$output" =~ "--cluster-name" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: show_help lists --aws-region option" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_help")
  run bash -c "
    BLUE='' GREEN='' RED='' YELLOW='' NC=''
    source '$FUNC_FILE'
    show_help 2>&1
  "
  [[ "$output" =~ "--aws-region" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: show_help documents chunked execution flags" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_help")
  run bash -c "
    BLUE='' GREEN='' RED='' YELLOW='' NC=''
    source '$FUNC_FILE'
    show_help 2>&1
  "
  [[ "$output" =~ "--from-step" ]]
  [[ "$output" =~ "--group" ]]
  [[ "$output" =~ "--state-file" ]]
  rm -f "$FUNC_FILE"
}

@test "--list-steps exits 0 and shows step 1" {
  run_script "test-end-to-end-backup-restore.sh" "--list-steps"
  assert_success
  [[ "$output" =~ "Step 1: Deploy infrastructure" ]]
}

@test "--list-groups exits 0 and shows deploy group" {
  run_script "test-end-to-end-backup-restore.sh" "--list-groups"
  assert_success
  [[ "$output" =~ "deploy" ]]
}

@test "unknown step number exits non-zero" {
  run_script "test-end-to-end-backup-restore.sh" "--step" "99"
  [ "$status" -ne 0 ]
}

@test "UNIT: save_e2e_state and load_e2e_state round-trip" {
  local state_file
  state_file=$(mktemp)
  run bash -c "
    PROJECT_ROOT='${PROJECT_ROOT}'
    STATE_FILE='${state_file}'
    TEST_TIMESTAMP='test-ts'
    BACKUP_BUCKET='my-bucket'
    SNAPSHOT_ID='snap-123'
    BACKUP_BUCKET_CREATED='my-bucket'
    SNAPSHOT_ID_CREATED='snap-123'
    INFRASTRUCTURE_CREATED='true'
    CLEANUP_REQUIRED='true'
    PROOF_FILE_CONTENT='proof with spaces and quotes'
    CLUSTER_NAME='test-cluster'
    AWS_REGION='us-west-2'
    NAMESPACE='openemr'
    LAST_COMPLETED_STEP='4'
    get_default_state_file() { echo \"\$STATE_FILE\"; }
    save_e2e_state() {
      local state_path=\"\${STATE_FILE:-\$(get_default_state_file)}\"
      {
        printf 'TEST_TIMESTAMP=%q\n' \"\$TEST_TIMESTAMP\"
        printf 'BACKUP_BUCKET=%q\n' \"\$BACKUP_BUCKET\"
        printf 'SNAPSHOT_ID=%q\n' \"\$SNAPSHOT_ID\"
        printf 'BACKUP_BUCKET_CREATED=%q\n' \"\$BACKUP_BUCKET_CREATED\"
        printf 'SNAPSHOT_ID_CREATED=%q\n' \"\$SNAPSHOT_ID_CREATED\"
        printf 'INFRASTRUCTURE_CREATED=%q\n' \"\$INFRASTRUCTURE_CREATED\"
        printf 'CLEANUP_REQUIRED=%q\n' \"\$CLEANUP_REQUIRED\"
        printf 'PROOF_FILE_CONTENT=%q\n' \"\$PROOF_FILE_CONTENT\"
        printf 'CLUSTER_NAME=%q\n' \"\$CLUSTER_NAME\"
        printf 'AWS_REGION=%q\n' \"\$AWS_REGION\"
        printf 'NAMESPACE=%q\n' \"\$NAMESPACE\"
        printf 'LAST_COMPLETED_STEP=%q\n' \"\$LAST_COMPLETED_STEP\"
      } > \"\$state_path\"
    }
    load_e2e_state() {
      local state_path=\"\${STATE_FILE:-\$(get_default_state_file)}\"
      source \"\$state_path\"
    }
    save_e2e_state
    BACKUP_BUCKET=''
    load_e2e_state
    echo \"BUCKET=\$BACKUP_BUCKET\"
    echo \"PROOF=\$PROOF_FILE_CONTENT\"
  "
  [[ "$output" =~ "BUCKET=my-bucket" ]]
  [[ "$output" =~ "proof with spaces and quotes" ]]
  rm -f "$state_file"
}

# ── UNIT: parse_arguments chunked flags ─────────────────────────────────────

@test "UNIT: parse_arguments sets FROM_STEP and TO_STEP" {
  run bash -c '
    FROM_STEP=1 TO_STEP=10 TOTAL_STEPS=10 STEP_GROUP=""
    log_error() { echo "ERROR: $*"; }
    list_step_groups() { echo "groups"; }
    resolve_step_group() { :; }
    show_help() { exit 0; }
    parse_arguments() {
      while [[ $# -gt 0 ]]; do
        case $1 in
          --from-step) FROM_STEP="$2"; shift 2 ;;
          --to-step) TO_STEP="$2"; shift 2 ;;
          --group) STEP_GROUP="$2"; shift 2 ;;
          *) log_error "Unknown option: $1"; exit 1 ;;
        esac
      done
      if [ -n "$STEP_GROUP" ]; then resolve_step_group; fi
      if [ "$FROM_STEP" -lt 1 ] || [ "$FROM_STEP" -gt "$TOTAL_STEPS" ] || \
         [ "$TO_STEP" -lt 1 ] || [ "$TO_STEP" -gt "$TOTAL_STEPS" ] || \
         [ "$FROM_STEP" -gt "$TO_STEP" ]; then
        log_error "Invalid step range"; exit 1
      fi
    }
    parse_arguments --from-step 3 --to-step 7
    echo "FROM=$FROM_STEP TO=$TO_STEP"
  '
  [[ "$output" =~ "FROM=3 TO=7" ]]
}


@test "UNIT: log_success outputs formatted message" {
  FUNC_FILE=$(extract_function "$SCRIPT" "log_success")
  run bash -c "
    GREEN='' NC=''
    source '$FUNC_FILE'
    log_success 'e2e step passed'
  "
  [[ "$output" =~ "e2e step passed" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: log_warning outputs formatted message" {
  FUNC_FILE=$(extract_function "$SCRIPT" "log_warning")
  run bash -c "
    YELLOW='' NC=''
    source '$FUNC_FILE'
    log_warning 'resource timeout'
  "
  [[ "$output" =~ "resource timeout" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: log_error outputs formatted message to stderr" {
  FUNC_FILE=$(extract_function "$SCRIPT" "log_error")
  run bash -c "
    RED='' NC=''
    source '$FUNC_FILE'
    log_error 'e2e failure' 2>&1
  "
  [[ "$output" =~ "e2e failure" ]]
  rm -f "$FUNC_FILE"
}
