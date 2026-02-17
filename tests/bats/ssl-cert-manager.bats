#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# BATS Suite: scripts/ssl-cert-manager.sh
# Purpose: Validate subcommand dispatch, every documented subcommand, usage
#          output content, default configuration, and get_aws_region logic.
# Scope:   Invokes only help and invalid-command paths.
# -----------------------------------------------------------------------------

load test_helper

setup() { cd "$PROJECT_ROOT"; }

SCRIPT="${SCRIPTS_DIR}/ssl-cert-manager.sh"

# ── Executable & syntax ─────────────────────────────────────────────────────

@test "ssl-cert-manager.sh is executable" {
  [ -x "$SCRIPT" ]
}

@test "ssl-cert-manager.sh has valid bash syntax" {
  bash -n "$SCRIPT"
}

# ── Help contract ───────────────────────────────────────────────────────────

@test "help subcommand exits 0" {
  run_script "ssl-cert-manager.sh" "help"
  assert_success
}

@test "help shows Usage line" {
  run_script "ssl-cert-manager.sh" "help"
  [[ "$output" =~ "Usage" ]]
}

# ── Help documents all subcommands ─────────────────────────────────────────

@test "help mentions 'request' subcommand" {
  run_script "ssl-cert-manager.sh" "help"
  [[ "$output" =~ "request" ]]
}

@test "help mentions 'list' subcommand" {
  run_script "ssl-cert-manager.sh" "help"
  [[ "$output" =~ "list" ]]
}

@test "help mentions 'validate' subcommand" {
  run_script "ssl-cert-manager.sh" "help"
  [[ "$output" =~ "validate" ]]
}

@test "help mentions 'deploy' subcommand" {
  run_script "ssl-cert-manager.sh" "help"
  [[ "$output" =~ "deploy" ]]
}

@test "help mentions 'status' subcommand" {
  run_script "ssl-cert-manager.sh" "help"
  [[ "$output" =~ "status" ]]
}

@test "help mentions 'auto-validate' subcommand" {
  run_script "ssl-cert-manager.sh" "help"
  [[ "$output" =~ "auto-validate" ]]
}

# ── No-args behavior ──────────────────────────────────────────────────────

@test "no args shows usage" {
  run_script "ssl-cert-manager.sh"
  [[ "$output" =~ "Usage" ]]
}

# ── Error handling ──────────────────────────────────────────────────────────

@test "unknown subcommand exits non-zero" {
  run_script "ssl-cert-manager.sh" "unknownsubcommand"
  [ "$status" -ne 0 ]
}

# ── Static analysis: config ────────────────────────────────────────────────

@test "get_aws_region function is defined" {
  run grep 'get_aws_region()' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "get_aws_region validates region format with regex" {
  run grep -A30 'get_aws_region()' "$SCRIPT"
  [[ "$output" =~ "a-z" ]]
  [[ "$output" =~ "0-9" ]]
}

@test "get_aws_region checks Terraform state first" {
  run grep -A10 'get_aws_region()' "$SCRIPT"
  [[ "$output" =~ "terraform.tfstate" ]]
}

@test "script defines show_usage function" {
  run grep 'show_usage()' "$SCRIPT"
  [ "$status" -eq 0 ]
}

# ── UNIT: show_usage ────────────────────────────────────────────────────────

@test "UNIT: show_usage prints Usage line" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_usage")
  run bash -c "
    BLUE='' NC=''
    source '$FUNC_FILE'
    show_usage
  "
  [[ "$output" =~ "Usage" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: show_usage lists all subcommands" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_usage")
  run bash -c "
    BLUE='' NC=''
    source '$FUNC_FILE'
    show_usage
  "
  [[ "$output" =~ "request" ]]
  [[ "$output" =~ "list" ]]
  [[ "$output" =~ "validate" ]]
  [[ "$output" =~ "deploy" ]]
  [[ "$output" =~ "status" ]]
  [[ "$output" =~ "auto-validate" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: show_usage includes Examples section" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_usage")
  run bash -c "
    BLUE='' NC=''
    source '$FUNC_FILE'
    show_usage
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

@test "UNIT: get_aws_region respects AWS_REGION env when non-default" {
  FUNC_FILE=$(extract_function "$SCRIPT" "get_aws_region")
  run bash -c "
    BLUE='' NC='' YELLOW=''
    TERRAFORM_DIR='/nonexistent/path'
    AWS_REGION='eu-west-1'
    source '$FUNC_FILE'
    get_aws_region
    echo \"\$AWS_REGION\"
  "
  [[ "$output" =~ "eu-west-1" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: get_aws_region rejects invalid region format" {
  FUNC_FILE=$(extract_function "$SCRIPT" "get_aws_region")
  run bash -c "
    BLUE='' NC='' YELLOW=''
    TERRAFORM_DIR='/nonexistent/path'
    AWS_REGION='not-a-region'
    source '$FUNC_FILE'
    get_aws_region
    echo \"\$AWS_REGION\"
  "
  [[ "$output" =~ "us-west-2" ]]
  rm -f "$FUNC_FILE"
}

# ── UNIT: show_manual_dns_instructions ──────────────────────────────────────

@test "UNIT: show_manual_dns_instructions includes console URL" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_manual_dns_instructions")
  run bash -c "
    YELLOW='' NC=''
    AWS_REGION='us-west-2'
    source '$FUNC_FILE'
    show_manual_dns_instructions 'arn:aws:acm:us-west-2:123456:certificate/abc-123'
  "
  [[ "$output" =~ "console.aws.amazon.com/acm" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: show_manual_dns_instructions includes region in URL" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_manual_dns_instructions")
  run bash -c "
    YELLOW='' NC=''
    AWS_REGION='eu-west-1'
    source '$FUNC_FILE'
    show_manual_dns_instructions 'arn:aws:acm:eu-west-1:123456:certificate/xyz-789'
  "
  [[ "$output" =~ "eu-west-1" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: show_manual_dns_instructions lists all 5 steps" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_manual_dns_instructions")
  run bash -c "
    YELLOW='' NC=''
    AWS_REGION='us-west-2'
    source '$FUNC_FILE'
    show_manual_dns_instructions 'arn:aws:acm:us-west-2:123456:certificate/test'
  "
  [[ "$output" =~ "1." ]]
  [[ "$output" =~ "2." ]]
  [[ "$output" =~ "3." ]]
  [[ "$output" =~ "4." ]]
  [[ "$output" =~ "5." ]]
  rm -f "$FUNC_FILE"
}

# ── UNIT: show_usage content depth ──────────────────────────────────────────

@test "UNIT: show_usage lists request subcommand" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_usage")
  run bash -c "
    YELLOW='' NC=''
    source '$FUNC_FILE'
    show_usage
  "
  [[ "$output" =~ "request" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: show_usage lists validate subcommand" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_usage")
  run bash -c "
    YELLOW='' NC=''
    source '$FUNC_FILE'
    show_usage
  "
  [[ "$output" =~ "validate" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: show_usage lists deploy subcommand" {
  FUNC_FILE=$(extract_function "$SCRIPT" "show_usage")
  run bash -c "
    YELLOW='' NC=''
    source '$FUNC_FILE'
    show_usage
  "
  [[ "$output" =~ "deploy" ]]
  rm -f "$FUNC_FILE"
}
