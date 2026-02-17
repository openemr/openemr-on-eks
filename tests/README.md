# OpenEMR on EKS – Tests

## Table of Contents

- [BATS (Bash Automated Testing System)](#bats-bash-automated-testing-system)
  - [Running BATS Tests](#running-bats-tests)
  - [Installing BATS](#installing-bats)
- [Test Design Standards](#test-design-standards)
  - [Uniform File Header](#uniform-file-header)
  - [Behavior-First Assertions](#behavior-first-assertions-required)
  - [Function-Level Unit Tests](#function-level-unit-tests)
- [Shared Helpers](#shared-helpers)
  - [Script Runners](#script-runners)
  - [Function Extraction](#function-extraction)
  - [Temp Fixture Helpers](#temp-fixture-helpers)
  - [Assertions](#assertions)
- [Adding New BATS Tests](#adding-new-bats-tests)
- [Test Coverage Summary](#test-coverage-summary)

---

This directory contains automated tests for the OpenEMR on EKS project.

## BATS (Bash Automated Testing System)

Script behavior tests live in `tests/bats/` and use [bats-core](https://github.com/bats-core/bats-core).

### Running BATS Tests

From the repository root:

```bash
# Run all BATS tests
bats tests/bats/

# Run a single test file
bats tests/bats/get-python-image-version.bats

# Run only function-level unit tests (filtered by name)
bats tests/bats/ --filter "UNIT"

# Run via the project test runner
cd scripts
./run-test-suite.sh -s script_validation
```

### Installing BATS

- Ubuntu/Debian: `sudo apt-get install bats`
- macOS: `brew install bats-core`
- Source: <https://bats-core.readthedocs.io/en/stable/installation.html>

If BATS is not installed, `run-test-suite.sh` skips BATS tests and continues with other script validation checks.

## Test Design Standards

### Uniform File Header

Every `*.bats` file uses a uniform header:

```bash
#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# BATS Suite: <script path>
# Purpose: <what contract/behavior this suite validates>
# Scope:   <what is and is not exercised (e.g., "no network calls")>
# -----------------------------------------------------------------------------
```

### Behavior-First Assertions (required)

Tests should prioritize behavior that protects long-term stability:

- **CLI contract:** `--help`, usage text, documented options
- **Parser correctness:** missing/invalid options return non-zero
- **Subcommand routing:** correct command/unknown command behavior
- **Guardrails:** fail-fast behavior when required dependencies are missing
- **Stable output contracts:** key banners/messages and structured output formats
- **Default values:** verify constants like `NAMESPACE`, `AWS_REGION`, timeouts

Avoid relying only on low-value checks (for example: existence-only or syntax-only tests) unless paired with behavior assertions.

### Function-Level Unit Tests

Each `.bats` file should include `UNIT:` prefixed tests that extract individual functions from the script under test and exercise them in isolation. This is the most valuable test category — it validates actual logic, not just script surface area.

**How it works:**

1. `extract_function` (from `test_helper.bash`) uses `awk` to pull a named function out of a script into a temp file.
2. The temp file is `source`d in a clean `bash -c` subshell with controlled variables (e.g., a custom `PROJECT_ROOT` pointing to a temp directory with a fixture `versions.yaml`).
3. The function is called directly and its output/exit code are asserted.

**Naming convention:** All function-level tests are prefixed with `UNIT:` so they can be filtered:

```bash
bats tests/bats/ --filter "UNIT"
```

**Example:**

```bats
@test "UNIT: normalize_python_version extracts major.minor from 3-part version" {
  local func_file
  func_file=$(extract_function "$SCRIPT" "normalize_python_version")
  run bash -c '
    source "'"$func_file"'"
    normalize_python_version "3.14.2"
  '
  rm -f "$func_file"
  [ "$status" -eq 0 ]
  [[ "$output" == "3.14" ]]
}
```

**When to use function extraction vs inlining:**

- **Use `extract_function`** for standalone functions that don't call other functions from the same script (e.g., `check_command`, `log`, `normalize_python_version`).
- **Inline the function body** when the function calls siblings (e.g., `filter_versions` calls `sort_versions`). Copy both into the `bash -c` block to avoid extraction dependency issues.
- **Use `make_temp_dir` / `make_temp_file`** to create fixture files (e.g., a custom `versions.yaml`) that control function inputs.

## Shared Helpers

`tests/bats/test_helper.bash` provides:

### Script Runners

| Helper | Purpose |
|--------|---------|
| `run_script <script> [args...]` | Run a script from `scripts/` |
| `run_script_from <rel_dir> <script> [args...]` | Run a script from any directory relative to `PROJECT_ROOT` |
| `run_script_stdout <script> [args...]` | Run a script capturing only stdout (stderr suppressed) |

### Function Extraction

| Helper | Purpose |
|--------|---------|
| `extract_function <script> <func_name>` | Extract a named function into a temp file; returns the file path |

### Temp Fixture Helpers

| Helper | Purpose |
|--------|---------|
| `make_temp_dir` | Create a disposable temp directory |
| `make_temp_file <content>` | Create a temp file with given content |

### Assertions

| Helper | Purpose |
|--------|---------|
| `assert_success` | Assert `$status` is 0 |
| `assert_failure` | Assert `$status` is non-zero |
| `assert_output_contains <str>` | Assert `$output` contains a substring |
| `assert_output_regex <pattern>` | Assert `$output` matches a regex |

## Adding New BATS Tests

1. Add a new `tests/bats/<script-name>.bats` file.
2. Include the uniform header and `load test_helper`.
3. Add behavior-first tests for:
   - help/usage contract
   - invalid/missing arg handling
   - at least one meaningful functionality/guardrail path
4. **Add `UNIT:` function-level tests** for every non-trivial function in the script:
   - Extract the function with `extract_function`
   - Source it in a clean subshell with controlled inputs
   - Assert output and exit codes
5. Keep tests non-destructive and deterministic in CI.

**Template:**

```bats
#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# BATS Suite: scripts/example.sh
# Purpose: Validate CLI usage, error handling, and function behavior.
# Scope:   Non-destructive — no network or infrastructure calls.
# -----------------------------------------------------------------------------

load test_helper

setup() { cd "$PROJECT_ROOT"; }

SCRIPT="${SCRIPTS_DIR}/example.sh"

# ── CLI contract ────────────────────────────────────────────────────────

@test "example.sh --help exits 0" {
  run_script "example.sh" "--help"
  [ "$status" -eq 0 ]
  [[ "$output" =~ Usage ]]
}

@test "example.sh unknown option fails" {
  run_script "example.sh" "--does-not-exist"
  [ "$status" -ne 0 ]
}

# ── Function-level unit tests ──────────────────────────────────────────

@test "UNIT: my_function returns expected value" {
  local func_file
  func_file=$(extract_function "$SCRIPT" "my_function")
  run bash -c '
    source "'"$func_file"'"
    my_function "input"
  '
  rm -f "$func_file"
  [ "$status" -eq 0 ]
  [[ "$output" == "expected_output" ]]
}
```

## Test Coverage Summary

**255 UNIT tests** across all 27 test files, covering function-level behavior for every script.

| Test File | Script | CLI Tests | UNIT Tests | Key Functions Tested |
|-----------|--------|-----------|------------|---------------------|
| `backup.bats` | `backup.sh` | 18 | 13 | `show_help`, `add_result`, `validate_backup_strategy`, `log_*` |
| `check-openemr-versions.bats` | `check-openemr-versions.sh` | 15 | 10 | `sort_versions`, `filter_versions`, `show_help` |
| `clean-deployment.bats` | `clean-deployment.sh` | 14 | 7 | arg parser flags, `get_aws_region` |
| `cluster-security-manager.bats` | `cluster-security-manager.sh` | 12 | 9 | `show_usage`, `get_aws_region` |
| `config_defaults.bats` | Multiple scripts | 15+ | 5 | `${VAR:-default}` patterns |
| `deploy-training-openemr-setup.bats` | `deploy-training-openemr-setup.sh` | 12 | 13 | `show_help`, `build_data_source`, `log_*`, `get_aws_region` |
| `destroy.bats` | `destroy.sh` | 14 | 11 | `show_help`, `log_*`, `get_aws_region` |
| `get-python-image-version.bats` | `get-python-image-version.sh` | 12 | 7 | `get_python_version_from_config`, `is_auto_detect_enabled` |
| `k8s_deploy.bats` | `k8s/deploy.sh` | 16 | 14 | `show_help`, `generate_password`, `log_*` |
| `monitoring.bats` | `install-monitoring.sh` | 14 | 12 | `check_command`, `generate_secure_password`, `alertmanager_enabled`, `retry_with_backoff`, `log_with_timestamp` |
| `oidc_provider.bats` | `oidc_provider/scripts/*` | 14 | 11 | `log_*`, `get_aws_region`, `confirm_destruction` |
| `openemr-feature-manager.bats` | `openemr-feature-manager.sh` | 12 | 9 | `show_help`, `get_aws_region`, `check_terraform_config` |
| `quick-deploy.bats` | `quick-deploy.sh` | 12 | 12 | `show_help`, `log_*`, `get_aws_region` |
| `restore-defaults.bats` | `restore-defaults.sh` | 11 | 8 | `show_help`, `create_backup`, `cleanup_*`, `restore_deployment_yaml` |
| `restore.bats` | `restore.sh` | 20 | 14 | `parse_arguments`, `explain_snapshot_status`, `show_help`, `aws_with_retry`, defaults |
| `scripts_common.bats` | Cross-cutting | 15+ | 6 | `extract_function`, `make_temp_dir`, `make_temp_file`, assertions |
| `search-codebase.bats` | `search-codebase.sh` | 9 | 4 | `search_codebase` |
| `ssl-cert-manager.bats` | `ssl-cert-manager.sh` | 12 | 12 | `show_usage`, `show_manual_dns_instructions`, `get_aws_region` |
| `ssl-renewal-manager.bats` | `ssl-renewal-manager.sh` | 12 | 9 | `print_usage`, `get_aws_region` |
| `test-end-to-end-backup-restore.bats` | `test-end-to-end-backup-restore.sh` | 12 | 14 | `show_help`, `start_timer`, `get_duration`, `add_test_result`, `parse_arguments`, `log_*` |
| `test-warp-end-to-end.bats` | `test-warp-end-to-end.sh` | 12 | 12 | `show_help`, `log_*`, `get_aws_region` |
| `test-warp-pinned-versions.bats` | `test-warp-pinned-versions.sh` | 11 | 6 | `normalize_python_version`, `read_version` |
| `validate-deployment.bats` | `validate-deployment.sh` | 11 | 10 | `check_command`, `get_aws_region`, function existence |
| `validate-efs-csi.bats` | `validate-efs-csi.sh` | 12 | 5 | `get_aws_region` |
| `version-manager.bats` | `version-manager.sh` | 12 | 13 | `log`, `normalize_version`, `compare_versions`, `show_help` |
| `versions_yaml.bats` | `versions.yaml` | 20+ | 5 | YAML structure validation |
| `warp_verify_counts.bats` | `verify-counts.sh` | 13 | 4 | `log` |
