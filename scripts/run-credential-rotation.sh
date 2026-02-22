#!/usr/bin/env bash
# =============================================================================
# Run Credential Rotation for OpenEMR on EKS
# =============================================================================
# Triggers a one-off Kubernetes Job to rotate RDS credentials using the
# dual-slot (A/B) strategy.  The Job updates sqlconf.php on EFS, patches the
# K8s Secret, performs a rolling restart, validates, and finalises.
#
# Prerequisites:
#   - kubectl configured for the target EKS cluster
#   - Terraform outputs available (or env vars set manually)
#   - Credential rotation container image built and pushed to ECR
#
# Usage:
#   ./scripts/run-credential-rotation.sh
#   ./scripts/run-credential-rotation.sh --dry-run
#   ./scripts/run-credential-rotation.sh --sync-db-users
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# Defaults (override via env vars)
# ---------------------------------------------------------------------------
: "${AWS_REGION:=us-west-2}"
: "${K8S_NAMESPACE:=openemr}"
: "${JOB_TIMEOUT:=2400s}"

# ---------------------------------------------------------------------------
# Resolve Terraform outputs
# ---------------------------------------------------------------------------
echo "=== Resolving Terraform outputs ==="
cd "$REPO_ROOT/terraform"

RDS_SLOT_SECRET_ARN=$(terraform output -raw rds_slot_secret_arn 2>/dev/null || echo "")
RDS_ADMIN_SECRET_ARN=$(terraform output -raw rds_admin_secret_arn 2>/dev/null || echo "")
CREDENTIAL_ROTATION_ROLE_ARN=$(terraform output -raw credential_rotation_role_arn 2>/dev/null || echo "")

if [[ -z "$RDS_SLOT_SECRET_ARN" || -z "$RDS_ADMIN_SECRET_ARN" ]]; then
    echo "ERROR: Could not resolve Secrets Manager ARNs from Terraform outputs."
    echo "       Run 'terraform apply' first to create rotation infrastructure."
    exit 1
fi

# ---------------------------------------------------------------------------
# Resolve rotation container image
# ---------------------------------------------------------------------------
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
: "${CREDENTIAL_ROTATION_IMAGE:=${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/openemr-credential-rotation:latest}"

# ---------------------------------------------------------------------------
# Build CLI args from script arguments (forwarded into the Job YAML)
# ---------------------------------------------------------------------------
CLI_ARGS=("--log-json")
for arg in "$@"; do
    CLI_ARGS+=("$arg")
done

# Build YAML-compatible JSON array for envsubst into the Job template
CREDENTIAL_ROTATION_ARGS="["
for i in "${!CLI_ARGS[@]}"; do
    (( i > 0 )) && CREDENTIAL_ROTATION_ARGS+=", "
    CREDENTIAL_ROTATION_ARGS+="\"${CLI_ARGS[$i]}\""
done
CREDENTIAL_ROTATION_ARGS+="]"
export CREDENTIAL_ROTATION_ARGS

# ---------------------------------------------------------------------------
# Delete any previous completed/failed Job
# ---------------------------------------------------------------------------
echo "=== Cleaning up previous rotation Jobs ==="
kubectl delete job credential-rotation -n "$K8S_NAMESPACE" --ignore-not-found=true

# ---------------------------------------------------------------------------
# Apply RBAC and ServiceAccount (idempotent)
# ---------------------------------------------------------------------------
echo "=== Applying RBAC and ServiceAccount ==="
export CREDENTIAL_ROTATION_ROLE_ARN
envsubst < "$REPO_ROOT/k8s/credential-rotation-sa.yaml" | kubectl apply -f -
kubectl apply -f "$REPO_ROOT/k8s/credential-rotation-rbac.yaml"

# ---------------------------------------------------------------------------
# Create and run the Job
# ---------------------------------------------------------------------------
echo "=== Launching credential rotation Job ==="

# Determine health check URL (best effort)
OPENEMR_HEALTHCHECK_URL=""
LB_HOST=$(kubectl get svc openemr-service -n "$K8S_NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
if [[ -n "$LB_HOST" ]]; then
    OPENEMR_HEALTHCHECK_URL="https://${LB_HOST}/interface/login/login.php"
fi

export AWS_REGION RDS_SLOT_SECRET_ARN RDS_ADMIN_SECRET_ARN
export CREDENTIAL_ROTATION_IMAGE OPENEMR_HEALTHCHECK_URL

envsubst < "$REPO_ROOT/k8s/credential-rotation-job.yaml" | kubectl apply -f -

echo "=== Waiting for Job completion (timeout: ${JOB_TIMEOUT}) ==="
if kubectl wait --for=condition=complete job/credential-rotation -n "$K8S_NAMESPACE" --timeout="$JOB_TIMEOUT"; then
    echo ""
    echo "=== Credential rotation completed successfully ==="
    kubectl logs job/credential-rotation -n "$K8S_NAMESPACE" --tail=20
else
    echo ""
    echo "=== Credential rotation FAILED ==="
    kubectl logs job/credential-rotation -n "$K8S_NAMESPACE" --tail=50
    exit 1
fi
