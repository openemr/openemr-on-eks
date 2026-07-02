#!/bin/bash
# Launch the full 10-step E2E backup/restore test with AWS credentials and logging.
# Run from your terminal (not via IDE agents) so the ~2.5 hr full test stays alive.
#
# Usage:
#   ./scripts/run-e2e-full-test.sh
#   ./scripts/run-e2e-full-test.sh --cluster-name openemr-eks-test --aws-region us-west-2

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LOG_FILE="${PROJECT_ROOT}/e2e-full-test.log"
AWS_PROFILE_NAME="${AWS_PROFILE_NAME:-440744216926_AdministratorAccess}"

load_credentials() {
    local config="${AWS_CONFIG_FILE:-$HOME/.aws/config}"
    if AWS_PROFILE="$AWS_PROFILE_NAME" aws sts get-caller-identity >/dev/null 2>&1; then
        export AWS_PROFILE="$AWS_PROFILE_NAME"
        return 0
    fi
    # Fallback: profile stored as [name] with keys in config (non-standard layout)
    if [ -f "$config" ] && python3 -c "import configparser; c=configparser.ConfigParser(); c.read('$config'); exit(0 if '$AWS_PROFILE_NAME' in c else 1)" 2>/dev/null; then
        eval "$(python3 <<PY
import configparser
c = configparser.ConfigParser()
c.read("$config")
s = c["$AWS_PROFILE_NAME"]
for k in ("aws_access_key_id", "aws_secret_access_key", "aws_session_token"):
    if k in s:
        print(f'export {k.upper()}="{s[k]}"')
PY
)"
        aws sts get-caller-identity >/dev/null
        return 0
    fi
    echo "Could not load AWS credentials for profile: $AWS_PROFILE_NAME" >&2
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
