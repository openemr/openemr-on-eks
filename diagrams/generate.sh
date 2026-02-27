#!/usr/bin/env bash
# =============================================================================
# Architecture Diagram Generator
# =============================================================================
# Generates an architecture diagram from the Terraform source code using
# Terravision (https://github.com/patrickchugh/terravision).
#
# Prerequisites:
#   pip install terravision   (or: pipx install terravision)
#   brew install graphviz     (macOS) / sudo apt-get install -y graphviz
#   brew install terraform    (or: tfenv install)
#   Valid AWS credentials configured (aws configure / SSO / env vars)
#
# Usage:
#   cd diagrams && ./generate.sh
#   # or from project root:
#   ./diagrams/generate.sh
# =============================================================================

set -euo pipefail

# Resolve paths relative to this script's location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TERRAFORM_DIR="${PROJECT_ROOT}/terraform"
OUTPUT_FILE="${SCRIPT_DIR}/architecture"

# --- Preflight checks --------------------------------------------------------

for cmd in terravision dot terraform; do
  if ! command -v "${cmd}" &>/dev/null; then
    echo "ERROR: '${cmd}' is not installed. See diagrams/README.md for prerequisites." >&2
    exit 1
  fi
done

if ! aws sts get-caller-identity &>/dev/null; then
  echo "ERROR: AWS credentials are not configured or have expired." >&2
  echo "       Terravision needs valid credentials so Terraform can run 'terraform plan'." >&2
  echo "       Configure credentials with 'aws configure' or 'aws sso login'." >&2
  exit 1
fi

if [ ! -d "${TERRAFORM_DIR}" ]; then
  echo "ERROR: Terraform directory not found at ${TERRAFORM_DIR}" >&2
  exit 1
fi

# --- Generate ----------------------------------------------------------------

echo "Generating architecture diagram from ${TERRAFORM_DIR} ..."
terravision draw --source "${TERRAFORM_DIR}" --outfile "${OUTPUT_FILE}"

# Terravision appends .dot before the extension; rename to the expected path
if [ -f "${OUTPUT_FILE}.dot.png" ]; then
  mv "${OUTPUT_FILE}.dot.png" "${OUTPUT_FILE}.png"
fi

if [ -f "${OUTPUT_FILE}.png" ]; then
  echo "Done — diagram written to diagrams/architecture.png ($(du -h "${OUTPUT_FILE}.png" | cut -f1) )"
else
  echo "ERROR: Diagram was not generated. Check terravision output above." >&2
  exit 1
fi
