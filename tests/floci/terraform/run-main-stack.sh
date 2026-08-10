#!/usr/bin/env bash
# Apply + destroy the main terraform/ root against Floci.
# Usage:
#   ./tests/floci/terraform/run-main-stack.sh [apply|destroy|apply-destroy|plan]
# Prerequisites: Floci on AWS_ENDPOINT_URL (default http://localhost:4566)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
TF_DIR="${PROJECT_ROOT}/terraform"
FLOCI_DIR="${PROJECT_ROOT}/tests/floci"
ACTION="${1:-apply-destroy}"
ENDPOINT="${AWS_ENDPOINT_URL:-http://localhost:4566}"
STATE_DIR="${TF_DIR}/.floci-state"
BACKEND_OVERRIDE="${TF_DIR}/zz_floci_backend_override.tf"
mkdir -p "${STATE_DIR}"

export AWS_ENDPOINT_URL="${ENDPOINT}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_EC2_METADATA_DISABLED=true
export AWS_PAGER=""
export TF_DATA_DIR="${STATE_DIR}/.terraform"

log() { echo "[floci-tf] $*" >&2; }

cleanup() {
  rm -f "${BACKEND_OVERRIDE}"
}
trap cleanup EXIT

if [ ! -x "${FLOCI_DIR}/wait.sh" ]; then
  chmod +x "${FLOCI_DIR}/wait.sh" || true
fi

log "Waiting for Floci at ${ENDPOINT}..."
"${FLOCI_DIR}/wait.sh" "${ENDPOINT}"

# Isolate Floci state under .floci-state/ (never terraform/terraform.tfstate)
cat > "${BACKEND_OVERRIDE}" <<EOF
terraform {
  backend "local" {
    path = "${STATE_DIR}/terraform.tfstate"
  }
}
EOF

cd "${TF_DIR}"

tf() {
  terraform "$@"
}

init_tf() {
  log "terraform init (local backend -> ${STATE_DIR}/terraform.tfstate)"
  tf init -reconfigure -input=false -lockfile=readonly
}

apply_tf() {
  log "terraform apply -var-file=terraform-floci.tfvars"
  tf apply -auto-approve -input=false -var-file=terraform-floci.tfvars
}

destroy_tf() {
  log "terraform destroy -var-file=terraform-floci.tfvars"
  tf destroy -auto-approve -input=false -var-file=terraform-floci.tfvars
}

case "${ACTION}" in
  apply)
    init_tf
    apply_tf
    ;;
  destroy)
    init_tf
    destroy_tf
    ;;
  apply-destroy)
    init_tf
    apply_tf
    destroy_tf
    ;;
  plan)
    init_tf
    tf plan -input=false -var-file=terraform-floci.tfvars
    ;;
  *)
    echo "Usage: $0 [apply|destroy|apply-destroy|plan]" >&2
    exit 2
    ;;
esac

log "Done (${ACTION})."
