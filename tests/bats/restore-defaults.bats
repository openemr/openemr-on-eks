#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# BATS Suite: scripts/restore-defaults.sh
# Purpose: Validate restore-defaults option parsing, --force and --backup flags,
#          help content completeness, and static analysis of restoration logic.
# Scope:   Invokes only --help and invalid-option paths.
# -----------------------------------------------------------------------------

load test_helper

setup() { cd "$PROJECT_ROOT"; }

SCRIPT="${SCRIPTS_DIR}/restore-defaults.sh"

# ── Executable & syntax ─────────────────────────────────────────────────────

@test "restore-defaults.sh is executable" {
  [ -x "$SCRIPT" ]
}

@test "restore-defaults.sh has valid bash syntax" {
  bash -n "$SCRIPT"
}

# ── Help contract ───────────────────────────────────────────────────────────

@test "--help exits 0" {
  run_script "restore-defaults.sh" "--help"
  assert_success
}

@test "--help shows Usage" {
  run_script "restore-defaults.sh" "--help"
  [[ "$output" =~ "Usage" ]]
}

# ── Help documents flags ───────────────────────────────────────────────────

@test "--help documents --force" {
  run_script "restore-defaults.sh" "--help"
  [[ "$output" =~ "--force" ]]
}

@test "--help documents --backup" {
  run_script "restore-defaults.sh" "--help"
  [[ "$output" =~ "--backup" ]]
}

@test "--help includes WARNING for developers" {
  run_script "restore-defaults.sh" "--help"
  [[ "$output" =~ (WARNING|ERASE|structural changes) ]]
}

@test "--help lists preserved files" {
  run_script "restore-defaults.sh" "--help"
  [[ "$output" =~ "terraform.tfvars" ]]
}

@test "--help mentions what gets restored" {
  run_script "restore-defaults.sh" "--help"
  [[ "$output" =~ (deployment.yaml|service.yaml|bak) ]]
}

# ── Error handling ──────────────────────────────────────────────────────────

@test "unknown option exits non-zero" {
  run_script "restore-defaults.sh" "--invalid"
  [ "$status" -ne 0 ]
}

@test "unknown option suggests help" {
  run_script "restore-defaults.sh" "--invalid"
  [[ "$output" =~ (help|Usage|usage) ]]
}

# ── Static analysis ────────────────────────────────────────────────────────

@test "script uses set -e" {
  run grep '^set -e' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script defines show_help function" {
  run grep 'show_help()' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script defines create_backup function" {
  run grep 'create_backup()' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script uses git checkout for restoration" {
  run grep 'git checkout' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script resolves PROJECT_ROOT" {
  run grep 'PROJECT_ROOT=' "$SCRIPT"
  [ "$status" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════
# Function-level unit tests
# These extract individual functions and test them in isolation.
# ═══════════════════════════════════════════════════════════════════════════

@test "UNIT: show_help outputs Usage line" {
  local func_file
  func_file=$(extract_function "$SCRIPT" "show_help")
  run bash -c '
    source "'"$func_file"'"
    show_help
  '
  rm -f "$func_file"
  # show_help calls exit 0
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Usage" ]]
}

@test "UNIT: show_help mentions --force option" {
  local func_file
  func_file=$(extract_function "$SCRIPT" "show_help")
  run bash -c '
    source "'"$func_file"'"
    show_help
  '
  rm -f "$func_file"
  [[ "$output" =~ "--force" ]]
}

@test "UNIT: show_help mentions --backup option" {
  local func_file
  func_file=$(extract_function "$SCRIPT" "show_help")
  run bash -c '
    source "'"$func_file"'"
    show_help
  '
  rm -f "$func_file"
  [[ "$output" =~ "--backup" ]]
}

@test "UNIT: show_help lists preserved files including terraform.tfvars" {
  local func_file
  func_file=$(extract_function "$SCRIPT" "show_help")
  run bash -c '
    source "'"$func_file"'"
    show_help
  '
  rm -f "$func_file"
  [[ "$output" =~ "terraform.tfvars" ]]
}

@test "UNIT: create_backup creates backup directory" {
  local func_file
  func_file=$(extract_function "$SCRIPT" "create_backup")
  local tmpdir
  tmpdir=$(make_temp_dir)
  # Create a minimal k8s directory structure
  mkdir -p "${tmpdir}/k8s"
  echo "test" > "${tmpdir}/k8s/deployment.yaml"

  run bash -c '
    GREEN="\033[0;32m"; YELLOW="\033[1;33m"; NC="\033[0m"
    PROJECT_ROOT="'"$tmpdir"'"
    source "'"$func_file"'"
    create_backup
  '
  rm -f "$func_file"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Backup created successfully" ]]
  # Verify backup directory was created
  run bash -c 'ls "'"${tmpdir}"'/backups/"'
  [ "$status" -eq 0 ]
  rm -rf "$tmpdir"
}

# ── UNIT: cleanup_backup_files ──────────────────────────────────────────────

@test "UNIT: cleanup_backup_files removes .bak files" {
  local tmpdir
  tmpdir=$(make_temp_dir)
  mkdir -p "${tmpdir}/k8s" "${tmpdir}/terraform"
  touch "${tmpdir}/k8s/deploy.yaml.bak" "${tmpdir}/terraform/main.tf.bak"

  FUNC_FILE=$(extract_function "$SCRIPT" "cleanup_backup_files")
  run bash -c "
    GREEN='' YELLOW='' NC=''
    PROJECT_ROOT='$tmpdir'
    source '$FUNC_FILE'
    cleanup_backup_files
  "
  assert_success
  [[ "$output" =~ "cleaned up" ]]
  # Verify .bak files were removed
  [ ! -f "${tmpdir}/k8s/deploy.yaml.bak" ]
  [ ! -f "${tmpdir}/terraform/main.tf.bak" ]
  rm -rf "$tmpdir" && rm -f "$FUNC_FILE"
}

# ── UNIT: cleanup_generated_files ───────────────────────────────────────────

@test "UNIT: cleanup_generated_files removes credential and temp files" {
  local tmpdir
  tmpdir=$(make_temp_dir)
  mkdir -p "${tmpdir}/k8s" "${tmpdir}/terraform"
  touch "${tmpdir}/k8s/openemr-credentials.txt"
  touch "${tmpdir}/k8s/something.tmp"

  FUNC_FILE=$(extract_function "$SCRIPT" "cleanup_generated_files")
  run bash -c "
    GREEN='' YELLOW='' NC=''
    PROJECT_ROOT='$tmpdir'
    source '$FUNC_FILE'
    cleanup_generated_files
  "
  assert_success
  [[ "$output" =~ "cleaned up" ]]
  [ ! -f "${tmpdir}/k8s/openemr-credentials.txt" ]
  [ ! -f "${tmpdir}/k8s/something.tmp" ]
  rm -rf "$tmpdir" && rm -f "$FUNC_FILE"
}

# ── UNIT: restore_deployment_yaml ───────────────────────────────────────────

@test "UNIT: restore_deployment_yaml attempts git checkout" {
  FUNC_FILE=$(extract_function "$SCRIPT" "restore_deployment_yaml")
  run bash -c "
    GREEN='' YELLOW='' NC=''
    PROJECT_ROOT='$PROJECT_ROOT'
    source '$FUNC_FILE'
    restore_deployment_yaml 2>&1
  "
  # It either restores from git or reports it can't
  [[ "$output" =~ "deployment.yaml" ]]
  rm -f "$FUNC_FILE"
}
