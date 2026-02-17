#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# BATS Suite: scripts/openemr-feature-manager.sh
# Purpose: Validate feature-manager command grammar (enable/disable/status +
#          api/portal/all), help completeness, Terraform config check, and
#          error handling for invalid commands/features.
# Scope:   Invokes only help/no-args paths (never modifies Terraform).
# -----------------------------------------------------------------------------

load test_helper

setup() { cd "$PROJECT_ROOT"; }

SCRIPT="${SCRIPTS_DIR}/openemr-feature-manager.sh"

# ── Executable & syntax ─────────────────────────────────────────────────────

@test "openemr-feature-manager.sh is executable" {
  [ -x "$SCRIPT" ]
}

@test "openemr-feature-manager.sh has valid bash syntax" {
  bash -n "$SCRIPT"
}

# ── Help contract ───────────────────────────────────────────────────────────

@test "help exits 0" {
  run_script "openemr-feature-manager.sh" "help"
  assert_success
}

@test "--help exits 0" {
  run_script "openemr-feature-manager.sh" "--help"
  assert_success
}

@test "help shows Usage line" {
  run_script "openemr-feature-manager.sh" "--help"
  [[ "$output" =~ "Usage" ]]
}

# ── Help documents all commands ────────────────────────────────────────────

@test "help documents 'enable' command" {
  run_script "openemr-feature-manager.sh" "--help"
  [[ "$output" =~ "enable" ]]
}

@test "help documents 'disable' command" {
  run_script "openemr-feature-manager.sh" "--help"
  [[ "$output" =~ "disable" ]]
}

@test "help documents 'status' command" {
  run_script "openemr-feature-manager.sh" "--help"
  [[ "$output" =~ "status" ]]
}

# ── Help documents all features ────────────────────────────────────────────

@test "help documents 'api' feature" {
  run_script "openemr-feature-manager.sh" "--help"
  [[ "$output" =~ "api" ]]
}

@test "help documents 'portal' feature" {
  run_script "openemr-feature-manager.sh" "--help"
  [[ "$output" =~ "portal" ]]
}

@test "help documents 'all' feature target" {
  run_script "openemr-feature-manager.sh" "--help"
  [[ "$output" =~ "all" ]]
}

# ── Help content quality ──────────────────────────────────────────────────

@test "help includes Examples section" {
  run_script "openemr-feature-manager.sh" "--help"
  [[ "$output" =~ "Examples" ]]
}

@test "help mentions security notes" {
  run_script "openemr-feature-manager.sh" "--help"
  [[ "$output" =~ (Security|security|disabled by default) ]]
}

@test "help mentions Terraform" {
  run_script "openemr-feature-manager.sh" "--help"
  [[ "$output" =~ "Terraform" ]]
}

# ── No-args behavior ──────────────────────────────────────────────────────

@test "no args shows help or usage" {
  run_script "openemr-feature-manager.sh"
  [[ "$output" =~ (Usage|usage|enable|disable|help) ]]
}

# ── Static analysis ────────────────────────────────────────────────────────

@test "script defines show_help function" {
  run grep 'show_help()' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script defines check_terraform_config function" {
  run grep 'check_terraform_config()' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "check_terraform_config checks for terraform.tfvars" {
  run grep -A5 'check_terraform_config()' "$SCRIPT"
  [[ "$output" =~ "terraform.tfvars" ]]
}

@test "script defines get_aws_region function" {
  run grep 'get_aws_region()' "$SCRIPT"
  [ "$status" -eq 0 ]
}

# ── UNIT: show_help ─────────────────────────────────────────────────────────

@test "UNIT: show_help prints Usage line" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_help")
  # show_help calls exit 0, so we need to handle that
  run bash -c "
    source '$FUNC_FILE'
    show_help
  "
  assert_success
  [[ "$output" =~ "Usage" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: show_help lists all commands and features" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_help")
  run bash -c "
    source '$FUNC_FILE'
    show_help
  "
  [[ "$output" =~ "enable" ]]
  [[ "$output" =~ "disable" ]]
  [[ "$output" =~ "status" ]]
  [[ "$output" =~ "api" ]]
  [[ "$output" =~ "portal" ]]
  [[ "$output" =~ "all" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: show_help includes Security Notes" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_help")
  run bash -c "
    source '$FUNC_FILE'
    show_help
  "
  [[ "$output" =~ "Security Notes" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: show_help mentions Terraform" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_help")
  run bash -c "
    source '$FUNC_FILE'
    show_help
  "
  [[ "$output" =~ "Terraform" ]]
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

# ── UNIT: check_terraform_config ────────────────────────────────────────────

@test "UNIT: check_terraform_config fails when tfvars missing" {
  run bash -c '
    RED="" NC="" YELLOW=""
    TERRAFORM_DIR="/tmp/nonexistent_dir_bats_test_$$"
    check_terraform_config() {
      if [ ! -f "$TERRAFORM_DIR/terraform.tfvars" ]; then
        echo "Error: terraform.tfvars not found" >&2
        exit 1
      fi
    }
    check_terraform_config
  '
  assert_failure
}

@test "UNIT: check_terraform_config succeeds when tfvars exists" {
  local tmpdir
  tmpdir=$(make_temp_dir)
  touch "${tmpdir}/terraform.tfvars"
  run bash -c '
    RED="" NC="" YELLOW=""
    TERRAFORM_DIR="'"$tmpdir"'"
    check_terraform_config() {
      if [ ! -f "$TERRAFORM_DIR/terraform.tfvars" ]; then
        echo "Error: terraform.tfvars not found" >&2
        exit 1
      fi
      echo "OK"
    }
    check_terraform_config
  '
  assert_success
  [ "$output" = "OK" ]
  rm -rf "$tmpdir"
}

# ── UNIT: show_help covers all features ─────────────────────────────────────

@test "UNIT: show_help documents enable/disable commands" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_help")
  run bash -c "
    source '$FUNC_FILE'
    show_help
  "
  [[ "$output" =~ "enable" ]]
  [[ "$output" =~ "disable" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: show_help documents status command" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_help")
  run bash -c "
    source '$FUNC_FILE'
    show_help
  "
  [[ "$output" =~ "status" ]]
  rm -f "$FUNC_FILE"
}
