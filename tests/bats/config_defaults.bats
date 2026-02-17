#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# BATS Suite: Cross-cutting configuration defaults
# Purpose: Guard against accidental drift of default values (CLUSTER_NAME,
#          AWS_REGION, NAMESPACE, timeouts) across all scripts. A change to any
#          default must be intentional and reflected everywhere.
# Scope:   Grep-based static analysis — never executes scripts.
# -----------------------------------------------------------------------------

load test_helper

setup() { cd "$PROJECT_ROOT"; }

# ── Canonical defaults ──────────────────────────────────────────────────────
# If a default changes, every test below breaks — that's the point.

@test "backup.sh default CLUSTER_NAME is 'openemr-eks'" {
  run grep 'CLUSTER_NAME.*openemr-eks' "${SCRIPTS_DIR}/backup.sh"
  [ "$status" -eq 0 ]
}

@test "backup.sh default AWS_REGION is 'us-west-2'" {
  run grep 'AWS_REGION.*us-west-2' "${SCRIPTS_DIR}/backup.sh"
  [ "$status" -eq 0 ]
}

@test "backup.sh default NAMESPACE is 'openemr'" {
  run grep 'NAMESPACE.*openemr' "${SCRIPTS_DIR}/backup.sh"
  [ "$status" -eq 0 ]
}

@test "backup.sh default BACKUP_STRATEGY is 'same-region'" {
  run grep 'BACKUP_STRATEGY.*same-region' "${SCRIPTS_DIR}/backup.sh"
  [ "$status" -eq 0 ]
}

@test "restore.sh default NAMESPACE is 'openemr'" {
  run grep 'DEFAULT_NAMESPACE.*openemr' "${SCRIPTS_DIR}/restore.sh"
  [ "$status" -eq 0 ]
}

@test "restore.sh default AWS_REGION is 'us-west-2'" {
  run grep 'DEFAULT_AWS_REGION.*us-west-2' "${SCRIPTS_DIR}/restore.sh"
  [ "$status" -eq 0 ]
}

@test "restore.sh default OpenEMR version is '8.0.0'" {
  run grep 'DEFAULT_OPENEMR_VERSION.*8.0.0' "${SCRIPTS_DIR}/restore.sh"
  [ "$status" -eq 0 ]
}

@test "clean-deployment.sh default NAMESPACE is 'openemr'" {
  run grep 'NAMESPACE.*openemr' "${SCRIPTS_DIR}/clean-deployment.sh"
  [ "$status" -eq 0 ]
}

@test "validate-deployment.sh default CLUSTER_NAME is 'openemr-eks'" {
  run grep 'CLUSTER_NAME.*openemr-eks' "${SCRIPTS_DIR}/validate-deployment.sh"
  [ "$status" -eq 0 ]
}

@test "validate-deployment.sh default NAMESPACE is 'openemr'" {
  run grep 'NAMESPACE.*openemr' "${SCRIPTS_DIR}/validate-deployment.sh"
  [ "$status" -eq 0 ]
}

@test "validate-efs-csi.sh default CLUSTER_NAME is 'openemr-eks'" {
  run grep 'CLUSTER_NAME.*openemr-eks' "${SCRIPTS_DIR}/validate-efs-csi.sh"
  [ "$status" -eq 0 ]
}

@test "ssl-cert-manager.sh default CLUSTER_NAME is 'openemr-eks'" {
  run grep 'CLUSTER_NAME.*openemr-eks' "${SCRIPTS_DIR}/ssl-cert-manager.sh"
  [ "$status" -eq 0 ]
}

@test "ssl-cert-manager.sh default NAMESPACE is 'openemr'" {
  run grep 'NAMESPACE.*openemr' "${SCRIPTS_DIR}/ssl-cert-manager.sh"
  [ "$status" -eq 0 ]
}

@test "destroy.sh default AWS_REGION is 'us-west-2'" {
  run grep 'AWS_REGION.*us-west-2' "${SCRIPTS_DIR}/destroy.sh"
  [ "$status" -eq 0 ]
}

@test "k8s/deploy.sh default NAMESPACE is 'openemr'" {
  run grep 'NAMESPACE_DEFAULT.*openemr' "${PROJECT_ROOT}/k8s/deploy.sh"
  [ "$status" -eq 0 ]
}

@test "k8s/deploy.sh default CLUSTER_NAME is 'openemr-eks'" {
  run grep 'CLUSTER_NAME_DEFAULT.*openemr-eks' "${PROJECT_ROOT}/k8s/deploy.sh"
  [ "$status" -eq 0 ]
}

# ── Timeout defaults ────────────────────────────────────────────────────────

@test "backup.sh default CLUSTER_AVAILABILITY_TIMEOUT is 1800" {
  run grep 'CLUSTER_AVAILABILITY_TIMEOUT.*1800' "${SCRIPTS_DIR}/backup.sh"
  [ "$status" -eq 0 ]
}

@test "backup.sh default POLLING_INTERVAL is 30" {
  run grep 'POLLING_INTERVAL.*30' "${SCRIPTS_DIR}/backup.sh"
  [ "$status" -eq 0 ]
}

@test "restore.sh default DB_CLUSTER_WAIT_TIMEOUT is 1200" {
  run grep 'DB_CLUSTER_WAIT_TIMEOUT.*1200' "${SCRIPTS_DIR}/restore.sh"
  [ "$status" -eq 0 ]
}

@test "restore.sh default POD_READY_WAIT_TIMEOUT is 600" {
  run grep 'POD_READY_WAIT_TIMEOUT.*600' "${SCRIPTS_DIR}/restore.sh"
  [ "$status" -eq 0 ]
}

@test "restore.sh default TEMP_POD_START_TIMEOUT is 300" {
  run grep 'TEMP_POD_START_TIMEOUT.*300' "${SCRIPTS_DIR}/restore.sh"
  [ "$status" -eq 0 ]
}

@test "k8s/deploy.sh POD_READY_TIMEOUT is 1800" {
  run grep 'POD_READY_TIMEOUT=1800' "${PROJECT_ROOT}/k8s/deploy.sh"
  [ "$status" -eq 0 ]
}

@test "k8s/deploy.sh ESSENTIAL_PVC_COUNT is 3" {
  run grep 'ESSENTIAL_PVC_COUNT=3' "${PROJECT_ROOT}/k8s/deploy.sh"
  [ "$status" -eq 0 ]
}

@test "clean-deployment.sh default DB_CLEANUP_MAX_ATTEMPTS is 24" {
  run grep 'DB_CLEANUP_MAX_ATTEMPTS.*24' "${SCRIPTS_DIR}/clean-deployment.sh"
  [ "$status" -eq 0 ]
}

@test "destroy.sh default BACKUP_JOB_WAIT_TIMEOUT is 180" {
  run grep 'BACKUP_JOB_WAIT_TIMEOUT.*180' "${SCRIPTS_DIR}/destroy.sh"
  [ "$status" -eq 0 ]
}

# ── Environment variable override pattern ──────────────────────────────────
# All config vars should use the ${VAR:-default} pattern for overridability.

@test "backup.sh CLUSTER_NAME uses env override pattern" {
  run grep 'CLUSTER_NAME=\${CLUSTER_NAME:-' "${SCRIPTS_DIR}/backup.sh"
  [ "$status" -eq 0 ]
}

@test "backup.sh AWS_REGION uses env override pattern" {
  run grep 'AWS_REGION=\${AWS_REGION:-' "${SCRIPTS_DIR}/backup.sh"
  [ "$status" -eq 0 ]
}

@test "backup.sh NAMESPACE uses env override pattern" {
  run grep 'NAMESPACE=\${NAMESPACE:-' "${SCRIPTS_DIR}/backup.sh"
  [ "$status" -eq 0 ]
}

@test "clean-deployment.sh NAMESPACE uses env override pattern" {
  run grep 'NAMESPACE=\${NAMESPACE:-' "${SCRIPTS_DIR}/clean-deployment.sh"
  [ "$status" -eq 0 ]
}

@test "validate-deployment.sh CLUSTER_NAME uses env override pattern" {
  run grep 'CLUSTER_NAME=\${CLUSTER_NAME:-' "${SCRIPTS_DIR}/validate-deployment.sh"
  [ "$status" -eq 0 ]
}

@test "restore.sh timeout vars use env override pattern" {
  run grep 'DB_CLUSTER_WAIT_TIMEOUT=\${DB_CLUSTER_WAIT_TIMEOUT:-' "${SCRIPTS_DIR}/restore.sh"
  [ "$status" -eq 0 ]
}

# ── set -e safety ──────────────────────────────────────────────────────────

@test "backup.sh uses set -e" {
  run grep '^set -e' "${SCRIPTS_DIR}/backup.sh"
  [ "$status" -eq 0 ]
}

@test "restore.sh uses set -euo pipefail" {
  run grep 'set -euo pipefail' "${SCRIPTS_DIR}/restore.sh"
  [ "$status" -eq 0 ]
}

@test "destroy.sh uses set -e" {
  run grep '^set -e' "${SCRIPTS_DIR}/destroy.sh"
  [ "$status" -eq 0 ]
}

@test "clean-deployment.sh uses set -e" {
  run grep '^set -e' "${SCRIPTS_DIR}/clean-deployment.sh"
  [ "$status" -eq 0 ]
}

@test "k8s/deploy.sh uses set -euo pipefail" {
  run grep 'set -euo pipefail' "${PROJECT_ROOT}/k8s/deploy.sh"
  [ "$status" -eq 0 ]
}

# ── UNIT: environment variable override pattern behavior ────────────────────

@test "UNIT: \${VAR:-default} pattern respects env override" {
  run bash -c '
    CLUSTER_NAME="${CLUSTER_NAME:-openemr-eks}"
    echo "$CLUSTER_NAME"
  '
  [ "$output" = "openemr-eks" ]
}

@test "UNIT: \${VAR:-default} pattern uses env when set" {
  run bash -c '
    export CLUSTER_NAME="custom-cluster"
    CLUSTER_NAME="${CLUSTER_NAME:-openemr-eks}"
    echo "$CLUSTER_NAME"
  '
  [ "$output" = "custom-cluster" ]
}

@test "UNIT: \${VAR:-default} pattern uses default when empty" {
  run bash -c '
    export CLUSTER_NAME=""
    CLUSTER_NAME="${CLUSTER_NAME:-openemr-eks}"
    echo "$CLUSTER_NAME"
  '
  [ "$output" = "openemr-eks" ]
}

@test "UNIT: nested \${VAR:-default} for AWS_REGION pattern" {
  run bash -c '
    unset AWS_REGION
    AWS_REGION="${AWS_REGION:-us-west-2}"
    echo "$AWS_REGION"
  '
  [ "$output" = "us-west-2" ]
}

@test "UNIT: nested \${VAR:-default} for NAMESPACE pattern" {
  run bash -c '
    export NAMESPACE="custom-ns"
    NAMESPACE="${NAMESPACE:-openemr}"
    echo "$NAMESPACE"
  '
  [ "$output" = "custom-ns" ]
}
