#!/usr/bin/env bash
# Runner-side seed for Floci integration and e2e-lite suites.
# Requires AWS_ENDPOINT_URL (and credentials) pointing at Floci.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/floci/env.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/env.sh"

CLUSTER_NAME="${FLOCI_CLUSTER_NAME:-openemr-eks-floci}"
REGION="${AWS_DEFAULT_REGION}"

echo "Seeding Floci resources for cluster=${CLUSTER_NAME} region=${REGION}..." >&2

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export FLOCI_ACCOUNT_ID="${ACCOUNT_ID}"

BACKUP_BUCKET="${FLOCI_BACKUP_BUCKET:-openemr-backups-${ACCOUNT_ID}-${CLUSTER_NAME}-$(date +%Y%m%d)}"
WARP_BUCKET="${FLOCI_WARP_BUCKET:-openemr-floci-warp-${ACCOUNT_ID}}"
WORK_BUCKET="${FLOCI_WORK_BUCKET:-openemr-floci-work-${ACCOUNT_ID}}"

for bucket in "${BACKUP_BUCKET}" "${WARP_BUCKET}" "${WORK_BUCKET}"; do
  if ! aws s3api head-bucket --bucket "${bucket}" 2>/dev/null; then
    aws s3 mb "s3://${bucket}" --region "${REGION}"
  fi
done

# KMS key + alias used by backup crypto smoke tests
if ! aws kms describe-key --key-id alias/openemr-floci-test >/dev/null 2>&1; then
  KEY_ID="$(aws kms create-key --description "OpenEMR Floci CI test key" --query KeyMetadata.KeyId --output text)"
  aws kms create-alias --alias-name alias/openemr-floci-test --target-key-id "${KEY_ID}"
fi

# Secrets Manager slot/admin-shaped secrets for credential-rotation integration
SLOT_SECRET_NAME="${FLOCI_SLOT_SECRET_NAME:-openemr/floci/rds-slots}"
ADMIN_SECRET_NAME="${FLOCI_ADMIN_SECRET_NAME:-openemr/floci/rds-admin}"

SLOT_PAYLOAD='{"active_slot":"A","A":{"username":"openemr","password":"slot-a-password"},"B":{"username":"openemr","password":"slot-b-password"}}'
ADMIN_PAYLOAD='{"username":"admin","password":"admin-password"}'

if ! aws secretsmanager describe-secret --secret-id "${SLOT_SECRET_NAME}" >/dev/null 2>&1; then
  aws secretsmanager create-secret --name "${SLOT_SECRET_NAME}" --secret-string "${SLOT_PAYLOAD}" >/dev/null
else
  aws secretsmanager put-secret-value --secret-id "${SLOT_SECRET_NAME}" --secret-string "${SLOT_PAYLOAD}" >/dev/null
fi

if ! aws secretsmanager describe-secret --secret-id "${ADMIN_SECRET_NAME}" >/dev/null 2>&1; then
  aws secretsmanager create-secret --name "${ADMIN_SECRET_NAME}" --secret-string "${ADMIN_PAYLOAD}" >/dev/null
else
  aws secretsmanager put-secret-value --secret-id "${ADMIN_SECRET_NAME}" --secret-string "${ADMIN_PAYLOAD}" >/dev/null
fi

# Mock RDS cluster metadata (FLOCI_SERVICES_RDS_MOCK=true)
RDS_CLUSTER_ID="${FLOCI_RDS_CLUSTER_ID:-openemr-floci-aurora}"
if ! aws rds describe-db-clusters --db-cluster-identifier "${RDS_CLUSTER_ID}" >/dev/null 2>&1; then
  aws rds create-db-cluster \
    --db-cluster-identifier "${RDS_CLUSTER_ID}" \
    --engine aurora-mysql \
    --engine-version 8.0.mysql_aurora.3.08.0 \
    --master-username openemr \
    --master-user-password 'SeedPassword123!' \
    --database-name openemr >/dev/null || true
fi

# Export paths for downstream suites / e2e-lite
export FLOCI_BACKUP_BUCKET="${BACKUP_BUCKET}"
export FLOCI_WARP_BUCKET="${WARP_BUCKET}"
export FLOCI_WORK_BUCKET="${WORK_BUCKET}"
export FLOCI_SLOT_SECRET_NAME="${SLOT_SECRET_NAME}"
export FLOCI_ADMIN_SECRET_NAME="${ADMIN_SECRET_NAME}"
export FLOCI_RDS_CLUSTER_ID="${RDS_CLUSTER_ID}"
export FLOCI_CLUSTER_NAME="${CLUSTER_NAME}"
export FLOCI_KMS_ALIAS="alias/openemr-floci-test"

# Persist for GitHub Actions job steps
if [ -n "${GITHUB_ENV:-}" ]; then
  {
    echo "FLOCI_ACCOUNT_ID=${FLOCI_ACCOUNT_ID}"
    echo "FLOCI_BACKUP_BUCKET=${FLOCI_BACKUP_BUCKET}"
    echo "FLOCI_WARP_BUCKET=${FLOCI_WARP_BUCKET}"
    echo "FLOCI_WORK_BUCKET=${FLOCI_WORK_BUCKET}"
    echo "FLOCI_SLOT_SECRET_NAME=${FLOCI_SLOT_SECRET_NAME}"
    echo "FLOCI_ADMIN_SECRET_NAME=${FLOCI_ADMIN_SECRET_NAME}"
    echo "FLOCI_RDS_CLUSTER_ID=${FLOCI_RDS_CLUSTER_ID}"
    echo "FLOCI_CLUSTER_NAME=${FLOCI_CLUSTER_NAME}"
    echo "FLOCI_KMS_ALIAS=${FLOCI_KMS_ALIAS}"
  } >> "${GITHUB_ENV}"
fi

echo "Floci seed complete:" >&2
echo "  account=${FLOCI_ACCOUNT_ID}" >&2
echo "  backup_bucket=${FLOCI_BACKUP_BUCKET}" >&2
echo "  warp_bucket=${FLOCI_WARP_BUCKET}" >&2
echo "  slot_secret=${FLOCI_SLOT_SECRET_NAME}" >&2
echo "  rds_cluster=${FLOCI_RDS_CLUSTER_ID}" >&2
