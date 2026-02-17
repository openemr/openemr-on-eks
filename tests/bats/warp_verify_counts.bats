#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# BATS Suite: warp/benchmark-data/verify-counts.sh
# Purpose: Validate argument/dependency guardrails, expected record counts,
#          S3 bucket configuration, and fail-fast behavior.
# Scope:   Non-destructive fail-fast paths before external downloads.
# -----------------------------------------------------------------------------

load test_helper

setup() { cd "$PROJECT_ROOT"; }

WARP_SCRIPT="${PROJECT_ROOT}/warp/benchmark-data/verify-counts.sh"

# ── Executable & syntax ─────────────────────────────────────────────────────

@test "verify-counts.sh is executable" {
  [ -x "$WARP_SCRIPT" ]
}

@test "verify-counts.sh has valid bash syntax" {
  bash -n "$WARP_SCRIPT"
}

# ── Dependency gate: aws cli ───────────────────────────────────────────────

@test "fails clearly when aws cli is unavailable" {
  run env PATH="/usr/bin:/bin" bash "$WARP_SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ (AWS CLI is not installed|Please install AWS CLI|ERROR) ]]
}

# ── Static analysis: expected counts ───────────────────────────────────────

@test "script defines PERSON count as 1000" {
  run grep -i 'PERSON.*1000\|1000.*PERSON\|person.*1,*000' "$WARP_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script references S3 bucket synpuf-omop" {
  run grep 'synpuf-omop' "$WARP_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script uses --no-sign-request for public bucket" {
  run grep 'no-sign-request' "$WARP_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script processes .bz2 compressed files" {
  run grep 'bz2' "$WARP_SCRIPT"
  [ "$status" -eq 0 ]
}

# ── Functions and structure ────────────────────────────────────────────────

@test "script defines download_dataset_files function" {
  run grep 'download_dataset_files()' "$WARP_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script defines log function" {
  run grep 'log()' "$WARP_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script uses set -e" {
  run grep '^set -e' "$WARP_SCRIPT"
  [ "$status" -eq 0 ]
}

# ── Dataset file names ─────────────────────────────────────────────────────

@test "script references CDM_PERSON dataset" {
  run grep 'CDM_PERSON' "$WARP_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script references CDM_CONDITION_OCCURRENCE dataset" {
  run grep 'CDM_CONDITION_OCCURRENCE' "$WARP_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script references CDM_DRUG_EXPOSURE dataset" {
  run grep 'CDM_DRUG_EXPOSURE' "$WARP_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script references CDM_OBSERVATION dataset" {
  run grep 'CDM_OBSERVATION' "$WARP_SCRIPT"
  [ "$status" -eq 0 ]
}

# ── --keep-downloaded-data flag ────────────────────────────────────────────

@test "script supports --keep-downloaded-data flag" {
  run grep 'keep-downloaded-data' "$WARP_SCRIPT"
  [ "$status" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════
# Function-level unit tests
# These extract individual functions and test them in isolation.
# ═══════════════════════════════════════════════════════════════════════════

@test "UNIT: log function outputs timestamped message to stderr" {
  local func_file
  func_file=$(extract_function "$WARP_SCRIPT" "log")
  run bash -c '
    source "'"$func_file"'"
    log "INFO" "test log message"
  '
  rm -f "$func_file"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "INFO" ]]
  [[ "$output" =~ "test log message" ]]
  # Should have timestamp format
  [[ "$output" =~ [0-9]{4}-[0-9]{2}-[0-9]{2} ]]
}

@test "UNIT: log function handles ERROR level" {
  local func_file
  func_file=$(extract_function "$WARP_SCRIPT" "log")
  run bash -c '
    source "'"$func_file"'"
    log "ERROR" "something failed"
  '
  rm -f "$func_file"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "ERROR" ]]
  [[ "$output" =~ "something failed" ]]
}

@test "UNIT: log function handles WARN level" {
  local func_file
  func_file=$(extract_function "$WARP_SCRIPT" "log")
  run bash -c '
    source "'"$func_file"'"
    log "WARN" "check this"
  '
  rm -f "$func_file"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "WARN" ]]
  [[ "$output" =~ "check this" ]]
}

@test "UNIT: log function includes timestamp" {
  local func_file
  func_file=$(extract_function "$WARP_SCRIPT" "log")
  run bash -c '
    source "'"$func_file"'"
    log "INFO" "timestamped"
  '
  rm -f "$func_file"
  [ "$status" -eq 0 ]
  [[ "$output" =~ [0-9]{2}:[0-9]{2}:[0-9]{2} ]]
}
