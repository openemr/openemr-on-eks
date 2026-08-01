#!/bin/bash
# Launch the full 10-step E2E backup/restore test with AWS credentials and logging.
# Run from your terminal (not via IDE agents) so the ~2.5 hr full test stays alive.
#
# Usage:
#   ./scripts/run-e2e-full-test.sh
#   AWS_PROFILE_NAME=my-profile ./scripts/run-e2e-full-test.sh
#   ./scripts/run-e2e-full-test.sh --cluster-name openemr-eks-test --aws-region us-west-2

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LOG_FILE="${PROJECT_ROOT}/e2e-full-test.log"
AWS_PROFILE_NAME="${AWS_PROFILE_NAME:-${AWS_PROFILE:-}}"

load_credentials() {
    # AWS_PROFILE_NAME is a backwards-compatible wrapper override. Otherwise,
    # honor AWS_PROFILE or the standard AWS credential provider chain.
    if [ -n "$AWS_PROFILE_NAME" ]; then
        export AWS_PROFILE="$AWS_PROFILE_NAME"
    fi

    if aws sts get-caller-identity >/dev/null 2>&1; then
        return 0
    fi

    if [ -n "$AWS_PROFILE_NAME" ]; then
        echo "Could not load AWS credentials for profile: $AWS_PROFILE_NAME" >&2
    else
        echo "Could not load AWS credentials from the default credential chain." >&2
        echo "Set AWS_PROFILE_NAME or AWS_PROFILE, or configure default AWS credentials." >&2
    fi
    exit 1
}

load_credentials

# Prefer project-local Terraform (matches versions.yaml) over system install
if [ -x "${PROJECT_ROOT}/.tools/bin/terraform" ]; then
    export PATH="${PROJECT_ROOT}/.tools/bin:${PATH}"
fi

echo "=== E2E full test started $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" | tee -a "$LOG_FILE"
echo "Account: $(aws sts get-caller-identity --query Account --output text)" | tee -a "$LOG_FILE"
echo "Log: $LOG_FILE" | tee -a "$LOG_FILE"

cd "$PROJECT_ROOT"
if [ $# -eq 0 ]; then
    set -- --cluster-name openemr-eks-test --aws-region us-west-2
fi

exec ./scripts/test-end-to-end-backup-restore.sh "$@" 2>&1 | tee -a "$LOG_FILE"
