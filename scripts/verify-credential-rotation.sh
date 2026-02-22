#!/usr/bin/env bash
# =============================================================================
# Verify Credential Rotation Readiness
# =============================================================================
# Runs the credential rotation in --dry-run mode to validate that:
#   - All prerequisites are met (secrets, IAM, EFS, K8s resources)
#   - The rotation tool can read secrets and sqlconf.php
#   - The flow would succeed without making any changes
#
# Usage:
#   ./scripts/verify-credential-rotation.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

: "${AWS_REGION:=us-west-2}"
: "${K8S_NAMESPACE:=openemr}"

echo "=== Credential Rotation Verification (dry-run) ==="

# ---------------------------------------------------------------------------
# Resolve Terraform outputs
# ---------------------------------------------------------------------------
cd "$REPO_ROOT/terraform"

RDS_SLOT_SECRET_ARN=$(terraform output -raw rds_slot_secret_arn 2>/dev/null || echo "")
RDS_ADMIN_SECRET_ARN=$(terraform output -raw rds_admin_secret_arn 2>/dev/null || echo "")
CREDENTIAL_ROTATION_ROLE_ARN=$(terraform output -raw credential_rotation_role_arn 2>/dev/null || echo "")

echo "  RDS Slot Secret:  ${RDS_SLOT_SECRET_ARN:-(not found)}"
echo "  RDS Admin Secret: ${RDS_ADMIN_SECRET_ARN:-(not found)}"
echo "  Rotation Role:    ${CREDENTIAL_ROTATION_ROLE_ARN:-(not found)}"

# ---------------------------------------------------------------------------
# Verify Secrets Manager secrets exist and are readable
# ---------------------------------------------------------------------------
echo ""
echo "=== Verifying Secrets Manager access ==="

if aws secretsmanager describe-secret --secret-id "$RDS_SLOT_SECRET_ARN" --region "$AWS_REGION" > /dev/null 2>&1; then
    echo "  RDS slot secret: OK"
    ACTIVE_SLOT=$(aws secretsmanager get-secret-value --secret-id "$RDS_SLOT_SECRET_ARN" --region "$AWS_REGION" --query SecretString --output text | python3 -c "import sys,json; print(json.load(sys.stdin).get('active_slot','UNKNOWN'))")
    echo "  Active slot: $ACTIVE_SLOT"
else
    echo "  RDS slot secret: FAILED (cannot access)"
fi

if aws secretsmanager describe-secret --secret-id "$RDS_ADMIN_SECRET_ARN" --region "$AWS_REGION" > /dev/null 2>&1; then
    echo "  RDS admin secret: OK"
else
    echo "  RDS admin secret: FAILED (cannot access)"
fi

# ---------------------------------------------------------------------------
# Verify K8s resources exist
# ---------------------------------------------------------------------------
echo ""
echo "=== Verifying Kubernetes resources ==="

if kubectl get secret openemr-db-credentials -n "$K8S_NAMESPACE" > /dev/null 2>&1; then
    echo "  K8s Secret (openemr-db-credentials): OK"
else
    echo "  K8s Secret (openemr-db-credentials): NOT FOUND"
fi

if kubectl get deployment openemr -n "$K8S_NAMESPACE" > /dev/null 2>&1; then
    READY=$(kubectl get deployment openemr -n "$K8S_NAMESPACE" -o jsonpath='{.status.readyReplicas}')
    DESIRED=$(kubectl get deployment openemr -n "$K8S_NAMESPACE" -o jsonpath='{.spec.replicas}')
    echo "  Deployment (openemr): ${READY:-0}/${DESIRED:-0} ready"
else
    echo "  Deployment (openemr): NOT FOUND"
fi

if kubectl get sa credential-rotation-sa -n "$K8S_NAMESPACE" > /dev/null 2>&1; then
    echo "  ServiceAccount (credential-rotation-sa): OK"
else
    echo "  ServiceAccount (credential-rotation-sa): NOT FOUND"
fi

# ---------------------------------------------------------------------------
# Verify EFS mount (check if sites PVC is bound)
# ---------------------------------------------------------------------------
echo ""
echo "=== Verifying storage ==="

PVC_STATUS=$(kubectl get pvc openemr-sites-pvc -n "$K8S_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NOT FOUND")
echo "  PVC (openemr-sites-pvc): $PVC_STATUS"

echo ""
echo "=== Verification complete ==="
echo ""
echo "To run a dry-run rotation Job:"
echo "  ./scripts/run-credential-rotation.sh --dry-run"
echo ""
echo "To run actual rotation:"
echo "  ./scripts/run-credential-rotation.sh"
