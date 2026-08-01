#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# BATS Suite: Cross-file contract & consistency tests
# Purpose: Validate that versions, names, outputs, and references stay in sync
#          across Terraform, K8s manifests, shell scripts, Dockerfiles, and
#          versions.yaml.  Catches the kind of drift that only surfaces at
#          deploy time today.
# Scope:   Read-only — inspects files, never modifies anything.
# -----------------------------------------------------------------------------

load test_helper

setup() {
  VERSIONS_FILE="${PROJECT_ROOT}/versions.yaml"
  OUTPUTS_TF="${PROJECT_ROOT}/terraform/outputs.tf"
  CRED_ROT_TF="${PROJECT_ROOT}/terraform/credential-rotation.tf"
  CRED_ROT_DOCKERFILE="${PROJECT_ROOT}/tools/credential-rotation/Dockerfile"
  CRED_ROT_REQUIREMENTS="${PROJECT_ROOT}/tools/credential-rotation/requirements.txt"
  WARP_REQUIREMENTS="${PROJECT_ROOT}/warp/requirements.txt"
  WARP_SETUP="${PROJECT_ROOT}/warp/setup.py"
  WARP_TEST_JOB="${PROJECT_ROOT}/warp/k8s-job-test.yaml"
  WARP_BENCHMARK_JOB="${PROJECT_ROOT}/warp/k8s-job-benchmark.yaml"
  WARP_E2E_SCRIPT="${PROJECT_ROOT}/scripts/test-warp-end-to-end.sh"
  MCP_PYPROJECT="${PROJECT_ROOT}/tools/codebase-mcp/pyproject.toml"
  CI_WORKFLOW="${PROJECT_ROOT}/.github/workflows/ci-cd-tests.yml"
  CONTRACT_WORKFLOW="${PROJECT_ROOT}/.github/workflows/ci-contract-tests.yml"
  CONSOLE_WORKFLOW="${PROJECT_ROOT}/.github/workflows/console-ci.yml"
  SECURITY_WORKFLOW="${PROJECT_ROOT}/.github/workflows/security-comprehensive.yml"
  WORKFLOWS_DIR="${PROJECT_ROOT}/.github/workflows"
  CONSOLE_GO_MOD="${PROJECT_ROOT}/console/go.mod"
  OIDC_MAIN_TF="${PROJECT_ROOT}/oidc_provider/main.tf"
  K8S_DIR="${PROJECT_ROOT}/k8s"
  VARIABLES_TF="${PROJECT_ROOT}/terraform/variables.tf"
  CLOUDWATCH_TF="${PROJECT_ROOT}/terraform/cloudwatch.tf"
  DEPLOYMENT_YAML="${K8S_DIR}/deployment.yaml"
  LOGGING_YAML="${K8S_DIR}/logging.yaml"
  K8S_DEPLOY_SCRIPT="${K8S_DIR}/deploy.sh"
}

# ── Helper: extract Terraform output names from outputs.tf + credential-rotation.tf ──
_all_tf_output_names() {
  grep -h '^output "' "$OUTPUTS_TF" "$CRED_ROT_TF" 2>/dev/null \
    | sed 's/output "\([^"]*\)".*/\1/' | sort -u
}

# ===========================================================================
# VERSION CONSISTENCY
# ===========================================================================

@test "CONTRACT: OpenEMR current version matches Terraform default and parameterized manifest" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  local yaml_ver terraform_ver
  yaml_ver=$(yq eval '.applications.openemr.current' "$VERSIONS_FILE")
  terraform_ver=$(awk '
    /^variable "openemr_version"/ { in_block = 1 }
    in_block && $1 == "default" {
      gsub(/"/, "", $3)
      print $3
      exit
    }
  ' "$VARIABLES_TF")

  [ "$terraform_ver" = "$yaml_ver" ]
  grep -Fq 'image: openemr/openemr:${OPENEMR_VERSION}' "$DEPLOYMENT_YAML"
  grep -Fq 's/\${OPENEMR_VERSION}/$OPENEMR_VERSION/g" deployment.yaml' "$K8S_DEPLOY_SCRIPT"
}

@test "CONTRACT: Fluent Bit current version matches deployment image" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  local yaml_ver manifest_ver
  yaml_ver=$(yq eval '.applications.fluent_bit.current' "$VERSIONS_FILE")
  manifest_ver=$(awk '
    $1 == "image:" && $2 ~ /^fluent\/fluent-bit:/ {
      sub(/^fluent\/fluent-bit:/, "", $2)
      print $2
      exit
    }
  ' "$DEPLOYMENT_YAML")

  [ "$manifest_ver" = "$yaml_ver" ]
}

@test "CONTRACT: credential rotation Dockerfile PYTHON_VERSION matches versions.yaml" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  local yaml_ver
  yaml_ver=$(yq eval '.applications.python.current' "$VERSIONS_FILE")
  local docker_ver
  docker_ver=$(grep '^ARG PYTHON_VERSION=' "$CRED_ROT_DOCKERFILE" | sed 's/ARG PYTHON_VERSION=//')
  [ "$docker_ver" = "$yaml_ver" ]
}

@test "CONTRACT: credential rotation requirements.txt boto3 version matches versions.yaml" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  local yaml_ver
  yaml_ver=$(yq eval '.python_packages.boto3.current' "$VERSIONS_FILE")
  run grep '^boto3' "$CRED_ROT_REQUIREMENTS"
  [[ "$output" == *"$yaml_ver"* ]]
}

@test "CONTRACT: credential rotation requirements.txt pymysql version matches versions.yaml" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  local yaml_ver
  yaml_ver=$(yq eval '.python_packages.pymysql.current' "$VERSIONS_FILE")
  run grep '^pymysql' "$CRED_ROT_REQUIREMENTS"
  [[ "$output" == *"$yaml_ver"* ]]
}

@test "CONTRACT: credential rotation requirements.txt kubernetes version matches versions.yaml" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  local yaml_ver
  yaml_ver=$(yq eval '.python_packages.kubernetes.current' "$VERSIONS_FILE")
  run grep '^kubernetes' "$CRED_ROT_REQUIREMENTS"
  [[ "$output" == *"$yaml_ver"* ]]
}

@test "CONTRACT: credential rotation requirements.txt requests version matches versions.yaml" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  local yaml_ver
  yaml_ver=$(yq eval '.python_packages.requests.current' "$VERSIONS_FILE")
  run grep '^requests' "$CRED_ROT_REQUIREMENTS"
  [[ "$output" == *"$yaml_ver"* ]]
}

@test "CONTRACT: warp requirements.txt pymysql version matches versions.yaml" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  local yaml_ver
  yaml_ver=$(yq eval '.python_packages.pymysql.current' "$VERSIONS_FILE")
  run grep '^pymysql' "$WARP_REQUIREMENTS"
  [[ "$output" == *"$yaml_ver"* ]]
}

@test "CONTRACT: CI workflow PYTHON_VERSION matches versions.yaml semver_packages" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  local yaml_ver
  yaml_ver=$(yq eval '.semver_packages.python_version.current' "$VERSIONS_FILE")
  run grep "PYTHON_VERSION:" "$CI_WORKFLOW"
  [[ "$output" == *"$yaml_ver"* ]]
}

@test "CONTRACT: manual-releases workflow PYTHON_VERSION matches versions.yaml semver_packages" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  local yaml_ver
  yaml_ver=$(yq eval '.semver_packages.python_version.current' "$VERSIONS_FILE")
  run grep "PYTHON_VERSION:" "${PROJECT_ROOT}/.github/workflows/manual-releases.yml"
  [[ "$output" == *"$yaml_ver"* ]]
}

@test "CONTRACT: CI workflow TERRAFORM_VERSION matches versions.yaml" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  local yaml_ver
  yaml_ver=$(yq eval '.semver_packages.terraform_version.current' "$VERSIONS_FILE")
  run grep "TERRAFORM_VERSION:" "$CI_WORKFLOW"
  [[ "$output" == *"$yaml_ver"* ]]
}

@test "CONTRACT: CI workflow KUBECTL_VERSION matches versions.yaml" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  local yaml_ver
  yaml_ver=$(yq eval '.semver_packages.kubectl_version.current' "$VERSIONS_FILE")
  run grep "KUBECTL_VERSION:" "$CI_WORKFLOW"
  [[ "$output" == *"$yaml_ver"* ]]
}

@test "CONTRACT: CI workflow UV_VERSION matches versions.yaml" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  local yaml_ver
  yaml_ver=$(yq eval '.python_packages.uv.current' "$VERSIONS_FILE")
  run grep "UV_VERSION:" "$CI_WORKFLOW"
  [[ "$output" == *"$yaml_ver"* ]]
}

@test "CONTRACT: knowledge MCP FastMCP pin matches versions.yaml" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  local yaml_ver
  yaml_ver=$(yq eval '.python_packages.fastmcp.current' "$VERSIONS_FILE")
  run grep -F "\"fastmcp==${yaml_ver}\"" "$MCP_PYPROJECT"
  [ "$status" -eq 0 ]
}

@test "CONTRACT: knowledge MCP PyYAML pin matches versions.yaml" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  local yaml_ver
  yaml_ver=$(yq eval '.python_packages.pyyaml.current' "$VERSIONS_FILE")
  run grep -F "\"PyYAML==${yaml_ver}\"" "$MCP_PYPROJECT"
  [ "$status" -eq 0 ]
}

@test "CONTRACT: KICS action version matches versions.yaml" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  local yaml_ver
  yaml_ver=$(yq eval '.security_tools.kics.current' "$VERSIONS_FILE")
  grep -Fq "KICS_VERSION: '${yaml_ver}'" "$SECURITY_WORKFLOW"
  grep -Fq "# ${yaml_ver}" "$SECURITY_WORKFLOW"
  [ "$(yq eval '.github_workflows.kics_action.current' "$VERSIONS_FILE")" = "$yaml_ver" ]
}

@test "CONTRACT: every external action uses its reviewed immutable SHA" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  local action_key current repository sha
  while IFS= read -r action_key; do
    current=$(yq eval ".github_workflows.${action_key}.current" "$VERSIONS_FILE")
    repository=$(yq eval ".github_workflows.${action_key}.repository" "$VERSIONS_FILE")
    sha=$(yq eval ".github_workflows.${action_key}.sha" "$VERSIONS_FILE")
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]]
    grep -R -Eq "uses: ${repository}(/[^@[:space:]]+)?@${sha} # ${current}" \
      "$WORKFLOWS_DIR" || {
      echo "Missing reviewed pin for ${repository}@${sha} (${current})"
      return 1
    }
  done < <(
    yq eval -r \
      '.github_workflows | to_entries | .[] | select(.value.repository != null) | .key' \
      "$VERSIONS_FILE"
  )
}

@test "CONTRACT: workflow action references are full commit SHAs" {
  local line reference
  while IFS= read -r line; do
    reference=$(sed -E 's/.*uses:[[:space:]]+[^@]+@([^[:space:]#]+).*/\1/' <<< "$line")
    [[ "$reference" =~ ^[0-9a-f]{40}$ ]] || {
      echo "Mutable action reference: $line"
      return 1
    }
  done < <(grep -R -E 'uses:[[:space:]]+[^[:space:]#]+@' "$WORKFLOWS_DIR")
}

@test "CONTRACT: Checkov has no baseline or soft-fail path" {
  [ ! -e "${PROJECT_ROOT}/.checkov.baseline" ]
  ! grep -Fq -- '--baseline' "$SECURITY_WORKFLOW"
  ! grep -Fq -- '--baseline' "${PROJECT_ROOT}/.pre-commit-config.yaml"
  ! grep -Fq -- '--soft-fail' "$SECURITY_WORKFLOW"
}

@test "CONTRACT: configurable OpenEMR version propagates to logging and SSL bootstrap" {
  grep -Fq 'Version     = var.openemr_version' "$CLOUDWATCH_TF"
  ! grep -Eq 'Version[[:space:]]*=[[:space:]]*"8\.' "$CLOUDWATCH_TF"
  grep -Fq 'Record              openemr_version ${OPENEMR_VERSION}' "$LOGGING_YAML"
  grep -Fq 's/\${OPENEMR_VERSION}/$OPENEMR_VERSION/g" logging.yaml' "$K8S_DEPLOY_SCRIPT"
  grep -Fq 'NAMESPACE="$NAMESPACE" OPENEMR_VERSION="$OPENEMR_VERSION"' "$K8S_DEPLOY_SCRIPT"
}

@test "CONTRACT: deployment renders tracked manifests only in a temporary directory" {
  grep -Fq 'MANIFEST_DIR=$(mktemp -d' "$K8S_DEPLOY_SCRIPT"
  grep -Fq 'cp "$SCRIPT_DIR"/*.yaml "$MANIFEST_DIR/"' "$K8S_DEPLOY_SCRIPT"
  grep -Fq 'cd "$MANIFEST_DIR"' "$K8S_DEPLOY_SCRIPT"
  grep -Fq 'trap cleanup_rendered_manifests EXIT' "$K8S_DEPLOY_SCRIPT"
  ! grep -Fq 'cd "$PROJECT_ROOT/k8s"' "$K8S_DEPLOY_SCRIPT"
}

@test "CONTRACT: Warp minimum Python matches boto3 compatibility" {
  grep -Fq 'python_requires=">=3.10"' "$WARP_SETUP"
  grep -Fq "python-version: ['3.10', '3.14.6']" "$CI_WORKFLOW"
}

@test "CONTRACT: Warp runtime PyMySQL pins match versions.yaml" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  local pymysql_ver
  pymysql_ver=$(yq eval '.python_packages.pymysql.current' "$VERSIONS_FILE")
  grep -Fq "pymysql==${pymysql_ver}" "$WARP_REQUIREMENTS"
  grep -Fq "pymysql==${pymysql_ver}" "$WARP_TEST_JOB"
  grep -Fq "pymysql==${pymysql_ver}" "$WARP_BENCHMARK_JOB"
  grep -Fq "pymysql==${pymysql_ver}" "$WARP_E2E_SCRIPT"
}

@test "CONTRACT: Go toolchain matches versions.yaml and gosec minimum" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  local go_ver gosec_min compatibility_source gosec_version
  go_ver=$(yq eval '.go_packages.go_version.current' "$VERSIONS_FILE")
  gosec_min=$(yq eval '.security_tools.gosec.minimum_go_version' "$VERSIONS_FILE")
  gosec_version=$(yq eval '.security_tools.gosec.current' "$VERSIONS_FILE")
  compatibility_source=$(yq eval '.security_tools.gosec.compatibility_source' "$VERSIONS_FILE")
  grep -Fq "go ${go_ver}" "$CONSOLE_GO_MOD"
  grep -Fq "GO_VERSION: '${go_ver}'" "$CONSOLE_WORKFLOW"
  grep -Fq "GO_VERSION: '${go_ver}'" "$SECURITY_WORKFLOW"
  grep -Fq "go-version: '${go_ver}'" "$CONTRACT_WORKFLOW"
  [ "$(printf '%s\n' "$gosec_min" "$go_ver" | sort -V | head -1)" = "$gosec_min" ]
  [[ "$compatibility_source" == *"${gosec_version}/go.mod" ]]
}

@test "CONTRACT: OIDC and primary Terraform roots use the same AWS provider" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  local aws_ver
  aws_ver=$(yq eval '.terraform_modules.terraform_aws.current' "$VERSIONS_FILE")
  grep -Fq "version = \"${aws_ver}\"" "$OIDC_MAIN_TF"
  grep -Fq "version = \"${aws_ver}\"" "${PROJECT_ROOT}/terraform/main.tf"
}

@test "CONTRACT: direct Terraform providers are exactly pinned and locked" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  local provider_key source version
  local lock_file="${PROJECT_ROOT}/terraform/.terraform.lock.hcl"
  [ -s "$lock_file" ]
  while IFS= read -r provider_key; do
    source=$(yq eval ".terraform_modules.${provider_key}.source" "$VERSIONS_FILE")
    version=$(yq eval ".terraform_modules.${provider_key}.current" "$VERSIONS_FILE")
    grep -Fq "source  = \"${source}\"" "${PROJECT_ROOT}/terraform/main.tf"
    grep -Fq "version = \"${version}\"" "${PROJECT_ROOT}/terraform/main.tf"
    grep -Fq "provider \"registry.terraform.io/${source}\"" "$lock_file"
  done < <(
    yq eval -r \
      '.terraform_modules | to_entries | .[] | select(.value.kind == "provider") | .key' \
      "$VERSIONS_FILE"
  )
  [ -s "${PROJECT_ROOT}/oidc_provider/.terraform.lock.hcl" ]
  grep -Fq 'provider "registry.terraform.io/hashicorp/aws"' \
    "${PROJECT_ROOT}/oidc_provider/.terraform.lock.hcl"
  grep -Fq 'terraform_version: 1.15.8' "$CONTRACT_WORKFLOW"
  grep -Fq 'terraform init -backend=false -lockfile=readonly' "$CONTRACT_WORKFLOW"
  ! grep -R -F 'terraform init -upgrade' \
    "${PROJECT_ROOT}/scripts" "${PROJECT_ROOT}/oidc_provider/scripts"
}

@test "CONTRACT: kubeconform validates rendered manifest templates" {
  grep -Fq 'envsubst "$substitutions"' "$CONTRACT_WORKFLOW"
  grep -Fq 'kubeconform -strict -ignore-missing-schemas' "$CONTRACT_WORKFLOW"
  ! grep -Fq 'Skipping template file' "$CONTRACT_WORKFLOW"
}

@test "CONTRACT: monthly version checks preserve and report lookup failures" {
  local workflow="${PROJECT_ROOT}/.github/workflows/monthly-version-check.yml"
  grep -Fq 'check_status=${PIPESTATUS[0]}' "$workflow"
  grep -Fq 'VERSION_CHECK_FAILED=true' "$workflow"
  grep -Fq '### ❌ Check Incomplete' "$workflow"
  ! grep -Eq 'version-manager\.sh.*\|\| echo' "$workflow"
}

# ===========================================================================
# TERRAFORM-TO-SCRIPT CONTRACT
# ===========================================================================

@test "CONTRACT: run-credential-rotation.sh terraform outputs exist in .tf files" {
  local script="${SCRIPTS_DIR}/run-credential-rotation.sh"
  local outputs
  outputs=$(_all_tf_output_names)
  for name in rds_slot_secret_arn rds_admin_secret_arn credential_rotation_role_arn; do
    echo "$outputs" | grep -qx "$name" || {
      echo "Missing Terraform output: $name (referenced in run-credential-rotation.sh)"
      return 1
    }
  done
}

@test "CONTRACT: verify-credential-rotation.sh terraform outputs exist in .tf files" {
  local script="${SCRIPTS_DIR}/verify-credential-rotation.sh"
  local outputs
  outputs=$(_all_tf_output_names)
  for name in rds_slot_secret_arn rds_admin_secret_arn credential_rotation_role_arn; do
    echo "$outputs" | grep -qx "$name" || {
      echo "Missing Terraform output: $name (referenced in verify-credential-rotation.sh)"
      return 1
    }
  done
}

@test "CONTRACT: backup.sh terraform outputs exist in outputs.tf" {
  local outputs
  outputs=$(_all_tf_output_names)
  echo "$outputs" | grep -qx "aurora_cluster_id"
}

@test "CONTRACT: restore.sh critical terraform outputs exist in outputs.tf" {
  local outputs
  outputs=$(_all_tf_output_names)
  for name in cluster_name aurora_cluster_id aurora_endpoint aurora_password efs_id openemr_role_arn aurora_db_subnet_group_name aurora_engine_version; do
    echo "$outputs" | grep -qx "$name" || {
      echo "Missing Terraform output: $name (referenced in restore.sh)"
      return 1
    }
  done
}

@test "CONTRACT: destroy.sh terraform outputs exist in outputs.tf" {
  local outputs
  outputs=$(_all_tf_output_names)
  for name in cluster_name alb_logs_bucket_name loki_s3_bucket_name tempo_s3_bucket_name mimir_blocks_s3_bucket_name alertmanager_s3_bucket_name backup_vault_name; do
    echo "$outputs" | grep -qx "$name" || {
      echo "Missing Terraform output: $name (referenced in destroy.sh)"
      return 1
    }
  done
}

@test "CONTRACT: every backup schedule includes all monitoring S3 buckets" {
  local backup_tf="${PROJECT_ROOT}/terraform/backup.tf"
  local count

  for bucket in loki_storage tempo_storage mimir_blocks_storage mimir_ruler_storage alertmanager_storage; do
    count=$(grep -c "aws_s3_bucket\\.${bucket}\\.arn" "$backup_tf")
    [ "$count" -eq 3 ] || {
      echo "$bucket must appear in daily, weekly, and monthly backup selections"
      return 1
    }
  done
}

# ===========================================================================
# K8S MANIFEST CONSISTENCY
# ===========================================================================

@test "CONTRACT: all credential rotation manifests use same ServiceAccount name" {
  local sa_name="credential-rotation-sa"
  grep -q "name: $sa_name" "$K8S_DIR/credential-rotation-sa.yaml"
  grep -q "serviceAccountName: $sa_name" "$K8S_DIR/credential-rotation-job.yaml"
  grep -q "serviceAccountName: $sa_name" "$K8S_DIR/credential-rotation-cronjob.yaml"
  grep -q "name: $sa_name" "$K8S_DIR/credential-rotation-rbac.yaml"
}

@test "CONTRACT: all credential rotation manifests use namespace 'openemr'" {
  for f in credential-rotation-sa.yaml credential-rotation-rbac.yaml credential-rotation-job.yaml credential-rotation-cronjob.yaml; do
    grep -q "namespace: openemr" "$K8S_DIR/$f" || {
      echo "Missing namespace: openemr in $f"
      return 1
    }
  done
}

@test "CONTRACT: credential rotation Job and CronJob use same container image variable" {
  local job_image cronjob_image
  job_image=$(grep 'image:' "$K8S_DIR/credential-rotation-job.yaml" | head -1 | awk '{print $2}')
  cronjob_image=$(grep 'image:' "$K8S_DIR/credential-rotation-cronjob.yaml" | head -1 | awk '{print $2}')
  [ "$job_image" = "$cronjob_image" ]
}

@test "CONTRACT: credential rotation Job and CronJob use same env vars" {
  local job_envs cronjob_envs
  job_envs=$(grep '- name:' "$K8S_DIR/credential-rotation-job.yaml" | awk '{print $3}' | sort)
  cronjob_envs=$(grep '- name:' "$K8S_DIR/credential-rotation-cronjob.yaml" | awk '{print $3}' | sort)
  [ "$job_envs" = "$cronjob_envs" ]
}

@test "CONTRACT: RBAC targets openemr-db-credentials Secret (matches secrets.yaml)" {
  grep -q 'openemr-db-credentials' "$K8S_DIR/credential-rotation-rbac.yaml"
  grep -q 'name: openemr-db-credentials' "$K8S_DIR/secrets.yaml"
}

@test "CONTRACT: RBAC targets 'openemr' Deployment (matches deployment.yaml)" {
  grep -q 'resourceNames: \["openemr"\]' "$K8S_DIR/credential-rotation-rbac.yaml" || \
  grep -q '"openemr"' "$K8S_DIR/credential-rotation-rbac.yaml"
  grep -q 'name: openemr' "$K8S_DIR/deployment.yaml"
}

@test "CONTRACT: Job K8S_SECRET_NAME env matches secrets.yaml Secret name" {
  local job_secret_name
  job_secret_name=$(grep -A1 'K8S_SECRET_NAME' "$K8S_DIR/credential-rotation-job.yaml" | grep 'value:' | awk -F'"' '{print $2}')
  grep -q "name: $job_secret_name" "$K8S_DIR/secrets.yaml"
}

@test "CONTRACT: all credential rotation manifests have consistent labels" {
  for f in credential-rotation-sa.yaml credential-rotation-rbac.yaml credential-rotation-job.yaml credential-rotation-cronjob.yaml; do
    grep -q 'app: credential-rotation' "$K8S_DIR/$f" || {
      echo "Missing label app: credential-rotation in $f"
      return 1
    }
  done
}

@test "CONTRACT: Job references openemr-sites-pvc PVC (must exist in storage.yaml)" {
  grep -q 'claimName: openemr-sites-pvc' "$K8S_DIR/credential-rotation-job.yaml"
  grep -q 'openemr-sites-pvc' "$K8S_DIR/storage.yaml"
}

# ===========================================================================
# SCRIPT-TO-FILE REFERENCES
# ===========================================================================

@test "CONTRACT: run-credential-rotation.sh references existing K8s manifests" {
  local script="${SCRIPTS_DIR}/run-credential-rotation.sh"
  for manifest in credential-rotation-rbac.yaml credential-rotation-sa.yaml credential-rotation-job.yaml; do
    if grep -q "$manifest" "$script"; then
      [ -f "$K8S_DIR/$manifest" ] || {
        echo "Referenced manifest $manifest does not exist"
        return 1
      }
    fi
  done
}

@test "CONTRACT: every k8s/*.yaml file is valid YAML (parseable)" {
  for f in "$K8S_DIR"/*.yaml; do
    python3 -c "import yaml; yaml.safe_load_all(open('$f'))" 2>/dev/null || {
      echo "Invalid YAML: $f"
      return 1
    }
  done
}

@test "CONTRACT: k8s deployment.yaml and service.yaml share 'app: openemr' selector" {
  grep -q 'app: openemr' "$K8S_DIR/deployment.yaml"
  grep -q 'app: openemr' "$K8S_DIR/service.yaml"
}

@test "CONTRACT: HPA targets 'openemr' Deployment (matches deployment.yaml)" {
  grep -q 'name: openemr' "$K8S_DIR/hpa.yaml"
  grep -q 'name: openemr' "$K8S_DIR/deployment.yaml"
}

@test "CONTRACT: all k8s manifests in openemr namespace use it consistently" {
  for f in deployment.yaml service.yaml secrets.yaml hpa.yaml storage.yaml; do
    if grep -q 'namespace:' "$K8S_DIR/$f"; then
      grep 'namespace:' "$K8S_DIR/$f" | grep -q 'openemr' || {
        echo "$f has a non-openemr namespace"
        return 1
      }
    fi
  done
}

@test "CONTRACT: EKS Auto Mode ALB uses an internal ClusterIP backend" {
  grep -q 'type: ClusterIP' "$K8S_DIR/service.yaml"
  ! grep -q 'type: LoadBalancer' "$K8S_DIR/service.yaml"
  grep -q 'controller: eks.amazonaws.com/alb' "$K8S_DIR/ingress.yaml"
  grep -q 'ingressClassName: openemr-alb' "$K8S_DIR/ingress.yaml"
}

# ===========================================================================
# DOCKERFILE & TOOL CONSISTENCY
# ===========================================================================

@test "CONTRACT: credential rotation Dockerfile installs from requirements.txt" {
  grep -q 'requirements.txt' "$CRED_ROT_DOCKERFILE"
}

@test "CONTRACT: credential rotation Dockerfile uses -slim base image" {
  grep -q 'python:.*-slim' "$CRED_ROT_DOCKERFILE"
}
