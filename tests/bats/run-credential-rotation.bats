#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# BATS Suite: scripts/run-credential-rotation.sh
# Purpose: Validate script structure, defaults, error handling, CLI argument
#          forwarding, and cleanup logic for the credential rotation runner.
# Scope:   Static analysis + function unit tests (no live cluster required).
# -----------------------------------------------------------------------------

load test_helper

setup() { cd "$PROJECT_ROOT"; }

SCRIPT="${SCRIPTS_DIR}/run-credential-rotation.sh"

# ── Executable & syntax ─────────────────────────────────────────────────────

@test "run-credential-rotation.sh is executable" {
  [ -x "$SCRIPT" ]
}

@test "run-credential-rotation.sh has valid bash syntax" {
  bash -n "$SCRIPT"
}

# ── Static analysis ────────────────────────────────────────────────────────

@test "script uses set -euo pipefail" {
  run grep 'set -euo pipefail' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script uses env bash shebang" {
  run head -1 "$SCRIPT"
  [[ "$output" =~ "#!/usr/bin/env bash" ]]
}

# ── Default values ──────────────────────────────────────────────────────────

@test "AWS_REGION defaults to us-west-2" {
  run grep 'AWS_REGION:=us-west-2' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "K8S_NAMESPACE defaults to openemr" {
  run grep 'K8S_NAMESPACE:=openemr' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "JOB_TIMEOUT defaults to 2400s" {
  run grep 'JOB_TIMEOUT:=2400s' "$SCRIPT"
  [ "$status" -eq 0 ]
}

# ── Terraform output resolution ────────────────────────────────────────────

@test "script resolves rds_slot_secret_arn from terraform" {
  run grep 'rds_slot_secret_arn' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script resolves rds_admin_secret_arn from terraform" {
  run grep 'rds_admin_secret_arn' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script resolves credential_rotation_role_arn from terraform" {
  run grep 'credential_rotation_role_arn' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script exits 1 when secret ARNs are empty" {
  run grep -A5 'Could not resolve Secrets Manager ARNs' "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "exit 1" ]]
}

# ── RBAC application ───────────────────────────────────────────────────────

@test "script applies credential-rotation-sa.yaml via envsubst" {
  run grep 'credential-rotation-sa.yaml' "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep 'envsubst' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script applies credential-rotation-rbac.yaml" {
  run grep 'credential-rotation-rbac.yaml' "$SCRIPT"
  [ "$status" -eq 0 ]
}

# ── Job lifecycle ──────────────────────────────────────────────────────────

@test "script deletes previous rotation Jobs before starting" {
  run grep 'kubectl delete job credential-rotation' "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "ignore-not-found" ]]
}

@test "script applies credential-rotation-job.yaml via envsubst" {
  run grep 'credential-rotation-job.yaml' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script waits for Job completion with timeout" {
  run grep 'kubectl wait.*condition=complete' "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "timeout" ]]
}

@test "script tails Job logs on success" {
  run grep 'kubectl logs job/credential-rotation' "$SCRIPT"
  [ "$status" -eq 0 ]
}

# ── CLI argument forwarding ────────────────────────────────────────────────

@test "script forwards --log-json by default" {
  run grep '\-\-log-json' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script iterates over arguments to build CLI_ARGS" {
  run grep 'CLI_ARGS' "$SCRIPT"
  [ "$status" -eq 0 ]
}

# ── Health check URL discovery ──────────────────────────────────────────────

@test "script discovers health check URL from LoadBalancer" {
  run grep 'loadBalancer.ingress' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "health check URL targets /interface/login/login.php" {
  run grep 'interface/login/login.php' "$SCRIPT"
  [ "$status" -eq 0 ]
}

# ── Image resolution ──────────────────────────────────────────────────────

@test "script constructs ECR image URI from account ID and region" {
  run grep 'openemr-credential-rotation' "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep 'dkr.ecr' "$SCRIPT"
  [ "$status" -eq 0 ]
}

# ── K8s manifest references ───────────────────────────────────────────────

@test "referenced K8s manifests exist" {
  [ -f "$PROJECT_ROOT/k8s/credential-rotation-sa.yaml" ]
  [ -f "$PROJECT_ROOT/k8s/credential-rotation-rbac.yaml" ]
  [ -f "$PROJECT_ROOT/k8s/credential-rotation-job.yaml" ]
}
