#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# BATS Suite: k8s/deploy.sh
# Purpose: Validate CLI contract, every documented flag, constant values,
#          required storage classes, timeout configuration, and parser robustness.
# Scope:   Invokes only --help and invalid-option paths (never deploys).
# -----------------------------------------------------------------------------

load test_helper

setup() { cd "$PROJECT_ROOT"; }

K8S_DEPLOY="${PROJECT_ROOT}/k8s/deploy.sh"

# ── Executable & syntax ─────────────────────────────────────────────────────

@test "k8s/deploy.sh is executable" {
  [ -x "$K8S_DEPLOY" ]
}

@test "k8s/deploy.sh has valid bash syntax" {
  bash -n "$K8S_DEPLOY"
}

# ── Help contract ───────────────────────────────────────────────────────────

@test "--help exits 0" {
  run_script_from "k8s" "deploy.sh" "--help"
  assert_success
}

@test "--help shows usage information" {
  run_script_from "k8s" "deploy.sh" "--help"
  [[ "$output" =~ (Usage|USAGE|Options) ]]
}

# ── Help documents every flag ───────────────────────────────────────────────

@test "--help documents --cluster-name" {
  run_script_from "k8s" "deploy.sh" "--help"
  [[ "$output" =~ "cluster-name" ]]
}

@test "--help documents --aws-region" {
  run_script_from "k8s" "deploy.sh" "--help"
  [[ "$output" =~ "aws-region" ]]
}

@test "--help documents --namespace" {
  run_script_from "k8s" "deploy.sh" "--help"
  [[ "$output" =~ "namespace" ]]
}

@test "--help documents --ssl-cert-arn" {
  run_script_from "k8s" "deploy.sh" "--help"
  [[ "$output" =~ "ssl-cert-arn" ]]
}

@test "--help documents --domain-name" {
  run_script_from "k8s" "deploy.sh" "--help"
  [[ "$output" =~ "domain-name" ]]
}

@test "--help mentions Prerequisites" {
  run_script_from "k8s" "deploy.sh" "--help"
  [[ "$output" =~ "Prerequisites" ]] || [[ "$output" =~ "prerequisites" ]]
}

# ── Error handling ──────────────────────────────────────────────────────────

@test "unknown option exits non-zero" {
  run_script_from "k8s" "deploy.sh" "--not-a-real-option"
  [ "$status" -ne 0 ]
}

@test "unknown option suggests help" {
  run_script_from "k8s" "deploy.sh" "--not-a-real-option"
  [[ "$output" =~ (Unknown option|help|Usage|usage) ]]
}

@test "missing option value fails cleanly" {
  run_script_from "k8s" "deploy.sh" "--cluster-name"
  [ "$status" -ne 0 ]
}

# ── Constants validation ───────────────────────────────────────────────────

@test "DEPLOYMENT_NAME is 'openemr'" {
  run grep 'DEPLOYMENT_NAME="openemr"' "$K8S_DEPLOY"
  [ "$status" -eq 0 ]
}

@test "SERVICE_NAME is 'openemr-service'" {
  run grep 'SERVICE_NAME="openemr-service"' "$K8S_DEPLOY"
  [ "$status" -eq 0 ]
}

@test "POD_READY_TIMEOUT is 1800 seconds" {
  run grep 'POD_READY_TIMEOUT=1800' "$K8S_DEPLOY"
  [ "$status" -eq 0 ]
}

@test "HEALTH_CHECK_TIMEOUT is 600 seconds" {
  run grep 'HEALTH_CHECK_TIMEOUT=600' "$K8S_DEPLOY"
  [ "$status" -eq 0 ]
}

@test "EFS_CSI_TIMEOUT is 300 seconds" {
  run grep 'EFS_CSI_TIMEOUT=300' "$K8S_DEPLOY"
  [ "$status" -eq 0 ]
}

@test "ESSENTIAL_PVC_COUNT is 3" {
  run grep 'ESSENTIAL_PVC_COUNT=3' "$K8S_DEPLOY"
  [ "$status" -eq 0 ]
}

# ── Required storage classes ────────────────────────────────────────────────

@test "storage class efs-sc is defined" {
  run grep 'efs-sc' "$K8S_DEPLOY"
  [ "$status" -eq 0 ]
}

@test "storage class efs-sc-backup is defined" {
  run grep 'efs-sc-backup' "$K8S_DEPLOY"
  [ "$status" -eq 0 ]
}

@test "storage class gp3-monitoring-encrypted is defined" {
  run grep 'gp3-monitoring-encrypted' "$K8S_DEPLOY"
  [ "$status" -eq 0 ]
}

# ── Script safety ──────────────────────────────────────────────────────────

@test "script uses set -euo pipefail" {
  run grep 'set -euo pipefail' "$K8S_DEPLOY"
  [ "$status" -eq 0 ]
}

@test "script resolves PROJECT_ROOT from SCRIPT_DIR" {
  run grep 'PROJECT_ROOT=.*SCRIPT_DIR' "$K8S_DEPLOY"
  [ "$status" -eq 0 ]
}

@test "TERRAFORM_DIR is derived from PROJECT_ROOT" {
  run grep 'TERRAFORM_DIR=.*PROJECT_ROOT' "$K8S_DEPLOY"
  [ "$status" -eq 0 ]
}

# ── UNIT: show_help ─────────────────────────────────────────────────────────

@test "UNIT: show_help prints usage" {
  FUNC_FILE=$(extract_function "$K8S_DEPLOY" "show_help")
  run bash -c "
    source '$FUNC_FILE'
    show_help
  "
  assert_success
  [[ "$output" =~ "Usage" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: show_help documents all CLI flags" {
  FUNC_FILE=$(extract_function "$K8S_DEPLOY" "show_help")
  run bash -c "
    source '$FUNC_FILE'
    show_help
  "
  [[ "$output" =~ "--cluster-name" ]]
  [[ "$output" =~ "--aws-region" ]]
  [[ "$output" =~ "--namespace" ]]
  [[ "$output" =~ "--help" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: show_help mentions prerequisites" {
  FUNC_FILE=$(extract_function "$K8S_DEPLOY" "show_help")
  run bash -c "
    source '$FUNC_FILE'
    show_help
  "
  [[ "$output" =~ "Prerequisites" ]]
  rm -f "$FUNC_FILE"
}

# ── UNIT: generate_password ─────────────────────────────────────────────────

@test "UNIT: generate_password returns string of default length 32" {
  FUNC_FILE=$(extract_function "$K8S_DEPLOY" "generate_password")
  run bash -c "
    source '$FUNC_FILE'
    pw=\$(generate_password)
    echo \${#pw}
  "
  assert_success
  [ "$output" = "32" ]
  rm -f "$FUNC_FILE"
}

@test "UNIT: generate_password respects custom length" {
  FUNC_FILE=$(extract_function "$K8S_DEPLOY" "generate_password")
  run bash -c "
    source '$FUNC_FILE'
    pw=\$(generate_password 16)
    echo \${#pw}
  "
  assert_success
  [ "$output" = "16" ]
  rm -f "$FUNC_FILE"
}

@test "UNIT: generate_password contains only alphanumeric chars" {
  FUNC_FILE=$(extract_function "$K8S_DEPLOY" "generate_password")
  run bash -c "
    source '$FUNC_FILE'
    pw=\$(generate_password)
    if [[ \"\$pw\" =~ ^[A-Za-z0-9]+$ ]]; then
      echo 'SAFE'
    else
      echo 'UNSAFE'
    fi
  "
  [ "$output" = "SAFE" ]
  rm -f "$FUNC_FILE"
}

# ── UNIT: log functions ─────────────────────────────────────────────────────

@test "UNIT: log_info outputs message" {
  FUNC_FILE=$(extract_function "$K8S_DEPLOY" "log_info")
  run bash -c "
    BLUE='' NC=''
    source '$FUNC_FILE'
    log_info 'hello world'
  "
  [[ "$output" =~ "hello world" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: log_header outputs decorated message" {
  FUNC_FILE=$(extract_function "$K8S_DEPLOY" "log_header")
  run bash -c "
    CYAN='' NC=''
    source '$FUNC_FILE'
    log_header 'Deploy Phase'
  "
  [[ "$output" =~ "Deploy Phase" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: log_success outputs message" {
  FUNC_FILE=$(extract_function "$K8S_DEPLOY" "log_success")
  run bash -c "
    GREEN='' NC=''
    source '$FUNC_FILE'
    log_success 'deployment healthy'
  "
  [[ "$output" =~ "deployment healthy" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: log_warning outputs message" {
  FUNC_FILE=$(extract_function "$K8S_DEPLOY" "log_warning")
  run bash -c "
    YELLOW='' NC=''
    source '$FUNC_FILE'
    log_warning 'pod not ready'
  "
  [[ "$output" =~ "pod not ready" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: log_error outputs message to stderr" {
  FUNC_FILE=$(extract_function "$K8S_DEPLOY" "log_error")
  run bash -c "
    RED='' NC=''
    source '$FUNC_FILE'
    log_error 'deployment failed' 2>&1
  "
  [[ "$output" =~ "deployment failed" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: log_step outputs step message" {
  FUNC_FILE=$(extract_function "$K8S_DEPLOY" "log_step")
  run bash -c "
    BLUE='' NC=''
    source '$FUNC_FILE'
    log_step 'configuring namespace'
  "
  [[ "$output" =~ "configuring namespace" ]]
  rm -f "$FUNC_FILE"
}

@test "UNIT: generate_password returns different values each call" {
  FUNC_FILE=$(extract_function "$K8S_DEPLOY" "generate_password")
  run bash -c "
    source '$FUNC_FILE'
    pw1=\$(generate_password 16)
    pw2=\$(generate_password 16)
    if [ \"\$pw1\" != \"\$pw2\" ]; then echo 'UNIQUE'; else echo 'DUPLICATE'; fi
  "
  [ "$output" = "UNIQUE" ]
  rm -f "$FUNC_FILE"
}

@test "UNIT: show_help documents --ssl-cert-arn flag" {
  FUNC_FILE=$(extract_function "$K8S_DEPLOY" "show_help")
  run bash -c "
    source '$FUNC_FILE'
    show_help
  "
  [[ "$output" =~ "ssl-cert-arn" ]]
  rm -f "$FUNC_FILE"
}
