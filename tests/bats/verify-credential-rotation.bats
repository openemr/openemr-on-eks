#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# BATS Suite: scripts/verify-credential-rotation.sh
# Purpose: Validate script structure, defaults, verification checks, and output
#          formatting for the credential rotation verifier.
# Scope:   Static analysis + function unit tests (no live cluster required).
# -----------------------------------------------------------------------------

load test_helper

setup() { cd "$PROJECT_ROOT"; }

SCRIPT="${SCRIPTS_DIR}/verify-credential-rotation.sh"

# ── Executable & syntax ─────────────────────────────────────────────────────

@test "verify-credential-rotation.sh is executable" {
  [ -x "$SCRIPT" ]
}

@test "verify-credential-rotation.sh has valid bash syntax" {
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

@test "script shows '(not found)' fallback for empty ARNs" {
  run grep '(not found)' "$SCRIPT"
  [ "$status" -eq 0 ]
}

# ── Secrets Manager verification ───────────────────────────────────────────

@test "script verifies RDS slot secret via describe-secret" {
  run grep 'aws secretsmanager describe-secret.*RDS_SLOT_SECRET_ARN' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script verifies RDS admin secret via describe-secret" {
  run grep 'aws secretsmanager describe-secret.*RDS_ADMIN_SECRET_ARN' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script reads active_slot from secret value" {
  run grep 'active_slot' "$SCRIPT"
  [ "$status" -eq 0 ]
}

# ── Kubernetes resource checks ─────────────────────────────────────────────

@test "script checks openemr-db-credentials K8s Secret" {
  run grep 'kubectl get secret openemr-db-credentials' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script checks openemr Deployment status" {
  run grep 'kubectl get deployment openemr' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script reports ready/desired replicas for Deployment" {
  run grep 'readyReplicas' "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep 'spec.replicas' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script checks credential-rotation-sa ServiceAccount" {
  run grep 'kubectl get sa credential-rotation-sa' "$SCRIPT"
  [ "$status" -eq 0 ]
}

# ── Storage verification ──────────────────────────────────────────────────

@test "script checks openemr-sites-pvc PVC status" {
  run grep 'openemr-sites-pvc' "$SCRIPT"
  [ "$status" -eq 0 ]
}

# ── Output formatting ─────────────────────────────────────────────────────

@test "script prints section headers with ===" {
  run grep -c '===.*===' "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" -ge 5 ]
}

@test "script prints dry-run and actual rotation instructions" {
  run grep '\-\-dry-run' "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep 'run-credential-rotation.sh' "$SCRIPT"
  [ "$status" -eq 0 ]
}
