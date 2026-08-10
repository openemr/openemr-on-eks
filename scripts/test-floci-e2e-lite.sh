#!/usr/bin/env bash
# =============================================================================
# Floci e2e-lite: CI-mocked backup/restore DR scenario
# =============================================================================
# Mirrors the high-level real-AWS e2e flow (seed → backup artifacts → simulate
# destroy → restore verification) using Floci-supported AWS APIs only.
#
# This does NOT replace the maintainer real-AWS gate documented in
# docs/END_TO_END_TESTING_REQUIREMENTS.md. It never runs terraform apply,
# k8s/deploy.sh, EFS proof files, monitoring install, or AWS Backup restore jobs.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FLOCI_DIR="${PROJECT_ROOT}/tests/floci"

usage() {
  cat <<'EOF'
Usage: test-floci-e2e-lite.sh [OPTIONS]

Run the Floci-backed e2e-lite DR scenario against AWS_ENDPOINT_URL.

Options:
  -h, --help     Show this help
  --skip-seed    Skip seed.sh (resources already present)

Environment:
  AWS_ENDPOINT_URL   Required Floci endpoint (e.g. http://localhost:4566)
  FLOCI_CLUSTER_NAME Optional cluster name used in bucket naming
EOF
}

SKIP_SEED=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --skip-seed)
      SKIP_SEED=true
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ -z "${AWS_ENDPOINT_URL:-}" ] && [ -z "${FLOCI_ENDPOINT:-}" ]; then
  echo "ERROR: AWS_ENDPOINT_URL (or FLOCI_ENDPOINT) is required. Point it at Floci before running e2e-lite." >&2
  echo "Hint: source tests/floci/env.sh after starting compose, or export AWS_ENDPOINT_URL=http://localhost:4566" >&2
  exit 1
fi

# shellcheck source=tests/floci/env.sh
# shellcheck disable=SC1091
source "${FLOCI_DIR}/env.sh"

step() {
  echo ""
  echo "=== [e2e-lite] $* ==="
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Step 1: Preflight
# ---------------------------------------------------------------------------
step "1/7 Preflight"
"${FLOCI_DIR}/wait.sh" "${AWS_ENDPOINT_URL}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" \
  || fail "STS get-caller-identity failed against Floci"
[ -n "${ACCOUNT_ID}" ] || fail "Empty account id from Floci STS"
REGION="${AWS_DEFAULT_REGION}"
CLUSTER_NAME="${FLOCI_CLUSTER_NAME:-openemr-eks-floci}"
echo "Account=${ACCOUNT_ID} Region=${REGION} Cluster=${CLUSTER_NAME}"

# ---------------------------------------------------------------------------
# Step 2: Seed
# ---------------------------------------------------------------------------
step "2/7 Seed"
if [ "${SKIP_SEED}" = false ]; then
  # shellcheck disable=SC1091
  source "${FLOCI_DIR}/seed.sh"
fi
BACKUP_BUCKET="${FLOCI_BACKUP_BUCKET:-openemr-backups-${ACCOUNT_ID}-${CLUSTER_NAME}-$(date +%Y%m%d)}"
RDS_CLUSTER_ID="${FLOCI_RDS_CLUSTER_ID:-openemr-floci-aurora}"
SLOT_SECRET="${FLOCI_SLOT_SECRET_NAME:-openemr/floci/rds-slots}"
KMS_ALIAS="${FLOCI_KMS_ALIAS:-alias/openemr-floci-test}"
WORK_BUCKET="${FLOCI_WORK_BUCKET:-openemr-floci-work-${ACCOUNT_ID}}"

aws s3api head-bucket --bucket "${BACKUP_BUCKET}" 2>/dev/null \
  || aws s3 mb "s3://${BACKUP_BUCKET}" --region "${REGION}"

# ---------------------------------------------------------------------------
# Step 3: Backup path (S3 layout + optional RDS snapshot + proof object)
# ---------------------------------------------------------------------------
step "3/7 Backup path"
PROOF_CONTENT="floci-e2e-lite-proof-$(date +%s)"
PROOF_KEY="application-data/proof.txt"
TMPDIR_E2E="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_E2E}"' EXIT

mkdir -p "${TMPDIR_E2E}/kubernetes" "${TMPDIR_E2E}/application-data" "${TMPDIR_E2E}/metadata" "${TMPDIR_E2E}/reports"
echo "${PROOF_CONTENT}" > "${TMPDIR_E2E}/application-data/proof.txt"
cat > "${TMPDIR_E2E}/kubernetes/resources.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: floci-e2e-lite
data:
  cluster: ${CLUSTER_NAME}
EOF
cat > "${TMPDIR_E2E}/metadata/backup-metadata.json" <<EOF
{
  "cluster_name": "${CLUSTER_NAME}",
  "aws_account": "${ACCOUNT_ID}",
  "aws_region": "${REGION}",
  "backup_bucket": "${BACKUP_BUCKET}",
  "rds_cluster_id": "${RDS_CLUSTER_ID}",
  "created_by": "test-floci-e2e-lite",
  "proof_key": "${PROOF_KEY}"
}
EOF
echo "Floci e2e-lite backup report OK" > "${TMPDIR_E2E}/reports/backup-report.txt"

aws s3 cp "${TMPDIR_E2E}/kubernetes/resources.yaml" "s3://${BACKUP_BUCKET}/kubernetes/resources.yaml" --region "${REGION}"
aws s3 cp "${TMPDIR_E2E}/application-data/proof.txt" "s3://${BACKUP_BUCKET}/${PROOF_KEY}" --region "${REGION}"
aws s3 cp "${TMPDIR_E2E}/metadata/backup-metadata.json" "s3://${BACKUP_BUCKET}/metadata/backup-metadata.json" --region "${REGION}"
aws s3 cp "${TMPDIR_E2E}/reports/backup-report.txt" "s3://${BACKUP_BUCKET}/reports/backup-report.txt" --region "${REGION}"

SNAPSHOT_ID="${RDS_CLUSTER_ID}-floci-$(date +%Y%m%d%H%M%S)"
SNAPSHOT_OK=false
if aws rds describe-db-clusters --db-cluster-identifier "${RDS_CLUSTER_ID}" >/dev/null 2>&1; then
  if aws rds create-db-cluster-snapshot \
      --db-cluster-identifier "${RDS_CLUSTER_ID}" \
      --db-cluster-snapshot-identifier "${SNAPSHOT_ID}" >/dev/null 2>&1; then
    if aws rds describe-db-cluster-snapshots \
        --db-cluster-snapshot-identifier "${SNAPSHOT_ID}" >/dev/null 2>&1; then
      SNAPSHOT_OK=true
      echo "Created Floci RDS mock snapshot: ${SNAPSHOT_ID}"
    fi
  fi
fi
if [ "${SNAPSHOT_OK}" = false ]; then
  echo "WARNING: RDS cluster snapshot APIs unavailable in this Floci mode; continuing with S3/Secrets/KMS path"
  SNAPSHOT_ID=""
fi

# Encrypt a small blob with the test KMS key to prove crypto path
PLAIN_B64="$(printf 'floci-backup-secret' | base64 | tr -d '\n')"
CIPHER="$(aws kms encrypt --key-id "${KMS_ALIAS}" --plaintext "${PLAIN_B64}" --query CiphertextBlob --output text)"
[ -n "${CIPHER}" ] || fail "KMS encrypt failed"

# Working marker bucket object that "destroy" will remove
aws s3 cp "${TMPDIR_E2E}/application-data/proof.txt" "s3://${WORK_BUCKET}/live/marker.txt" --region "${REGION}"

# ---------------------------------------------------------------------------
# Step 4: Simulate destroy (remove non-backup working markers)
# ---------------------------------------------------------------------------
step "4/7 Simulate destroy"
aws s3 rm "s3://${WORK_BUCKET}/live/marker.txt" --region "${REGION}" || true
if aws s3 ls "s3://${WORK_BUCKET}/live/marker.txt" --region "${REGION}" >/dev/null 2>&1; then
  fail "Working marker still present after simulate-destroy"
fi
echo "Working markers cleared; backup bucket preserved: ${BACKUP_BUCKET}"

# ---------------------------------------------------------------------------
# Step 5: Restore path (re-read S3 artifacts + secrets + snapshot)
# ---------------------------------------------------------------------------
step "5/7 Restore path"
aws s3 cp "s3://${BACKUP_BUCKET}/metadata/backup-metadata.json" "${TMPDIR_E2E}/restored-metadata.json" --region "${REGION}"
aws s3 cp "s3://${BACKUP_BUCKET}/${PROOF_KEY}" "${TMPDIR_E2E}/restored-proof.txt" --region "${REGION}"
aws s3 cp "s3://${BACKUP_BUCKET}/kubernetes/resources.yaml" "${TMPDIR_E2E}/restored-k8s.yaml" --region "${REGION}"

SECRET_JSON="$(aws secretsmanager get-secret-value --secret-id "${SLOT_SECRET}" --query SecretString --output text)"
echo "${SECRET_JSON}" | grep -q 'active_slot' || fail "Slot secret missing active_slot after restore path"

if [ -n "${SNAPSHOT_ID}" ]; then
  aws rds describe-db-cluster-snapshots --db-cluster-snapshot-identifier "${SNAPSHOT_ID}" >/dev/null \
    || fail "Snapshot ${SNAPSHOT_ID} not describable during restore path"
fi

DECRYPTED="$(aws kms decrypt --ciphertext-blob "${CIPHER}" --query Plaintext --output text)"
[ "${DECRYPTED}" = "${PLAIN_B64}" ] || fail "KMS decrypt round-trip mismatch"

# ---------------------------------------------------------------------------
# Step 6: Verify
# ---------------------------------------------------------------------------
step "6/7 Verify"
RESTORED_PROOF="$(cat "${TMPDIR_E2E}/restored-proof.txt")"
[ "${RESTORED_PROOF}" = "${PROOF_CONTENT}" ] || fail "Proof content mismatch"
grep -q "\"cluster_name\": \"${CLUSTER_NAME}\"" "${TMPDIR_E2E}/restored-metadata.json" \
  || grep -q "\"cluster_name\":\"${CLUSTER_NAME}\"" "${TMPDIR_E2E}/restored-metadata.json" \
  || fail "Restored metadata missing cluster_name"
grep -q "floci-e2e-lite" "${TMPDIR_E2E}/restored-k8s.yaml" || fail "Restored kubernetes artifact missing expected content"
# Re-publish proof to work bucket as "restored live" marker
aws s3 cp "${TMPDIR_E2E}/restored-proof.txt" "s3://${WORK_BUCKET}/live/marker.txt" --region "${REGION}"
aws s3 ls "s3://${WORK_BUCKET}/live/marker.txt" --region "${REGION}" >/dev/null \
  || fail "Restored live marker missing"

echo "Verification OK (proof, metadata, secrets, kms${SNAPSHOT_ID:+, snapshot})"

# ---------------------------------------------------------------------------
# Step 7: Cleanup (best-effort; memory mode is ephemeral per CI job)
# ---------------------------------------------------------------------------
step "7/7 Cleanup"
aws s3 rm "s3://${BACKUP_BUCKET}" --recursive --region "${REGION}" >/dev/null 2>&1 || true
aws s3 rm "s3://${WORK_BUCKET}/live/" --recursive --region "${REGION}" >/dev/null 2>&1 || true

echo ""
echo "Floci e2e-lite PASSED"
echo "Note: real-AWS 10-step e2e remains the release gate for full DR fidelity."
