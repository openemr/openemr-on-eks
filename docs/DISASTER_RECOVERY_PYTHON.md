# Disaster Recovery — Python Architecture

OpenEMR backup, restore, and E2E testing are migrating from large bash scripts to the **`openemr_dr`** Python package under `scripts/openemr_dr/`. Bash entrypoints remain for compatibility but delegate to Python.

## Why Python

- **Testable phases** — each restore step has unit tests; no AWS required for most tests
- **Checkpoints** — `.restore-state` with `--from-phase` resume after long failures
- **Manifest v2** — typed restore plans from backup metadata
- **Single orchestrator** — one code path for CLI, E2E step 8, and future automation

## Package layout

```
scripts/openemr_dr/
  cli.py                 # python -m openemr_dr {restore|backup|e2e}
  common/                # shell helpers, paths, logging
  aws/                   # RDS, KMS, wait, terraform_data
  models/                # RestoreContext, RestoreState
  backup/                # manifest builder, metadata loader, orchestrator
  restore/
    orchestrator.py      # phased restore runner
    bash_bridge.py       # legacy phase only
    phases/              # all restore phases (native Python)
  e2e/runner.py          # E2E driver (delegates to bash E2E today)
  tests/                 # pytest suite (91%+ coverage)
  pyproject.toml         # ruff, mypy strict, bandit, pytest-cov 90%
```

## Restore flow (default — inverted)

| Phase | Implementation | What it does |
|-------|----------------|--------------|
| `preflight` | Python | Validate Terraform state, S3 application data, snapshot availability, and AWS identity |
| `bootstrap` | Python → `k8s/restore-bootstrap.sh` | Namespace, EFS PVC, IRSA |
| `rds` | Python | Destroy empty cluster, restore from snapshot / AWS Backup |
| `data` | Python | Apply `k8s/jobs/data-restore-job.yaml`; Job drops all capabilities and extracts with `tar --no-same-owner` |
| `deploy` | Python → shell scripts | Restore defaults, ensure EFS CSI, deploy, remove `openemr-hpa`, prepare one replica, clean crypto keys |
| `verify` | Python | Poll pod/HTTP health, clean crypto keys between retries, render pristine `hpa.yaml` from Terraform outputs, and re-apply the HPA |
| `legacy` | Bash bridge | Old restore order only |

## Usage

### Restore

```bash
# Default (Python orchestrator via restore.sh wrapper)
./scripts/restore.sh BACKUP_BUCKET SNAPSHOT_ID --region us-west-2

# From manifest v2
./scripts/restore.sh --from-metadata s3://BUCKET/metadata/backup-metadata-TIMESTAMP.json

# Direct Python CLI
PYTHONPATH=scripts python3 -m openemr_dr restore \
  BACKUP_BUCKET SNAPSHOT_ID --region us-west-2

# Single phase (for debugging)
PYTHONPATH=scripts python3 -m openemr_dr restore \
  BUCKET SNAP --phase preflight --dry-run

# Resume after failure
PYTHONPATH=scripts python3 -m openemr_dr restore \
  BUCKET SNAP --from-phase data --state-file .restore-state

# Legacy order through the Python orchestrator's Bash bridge
PYTHONPATH=scripts python3 -m openemr_dr restore BUCKET SNAP --legacy-order

# Bypass Python and force the Bash implementation
./scripts/restore.sh BUCKET SNAP --legacy-order --bash-only
```

### E2E tests

```bash
# Python driver for the full contiguous E2E range
(cd scripts && python3 -m openemr_dr e2e \
  --group full --cluster-name openemr-eks-test --aws-region us-west-2)

# Fast in-place restore tier (steps 4 and 8-9) currently requires the bash
# group so that steps 5-7 remain skipped
AWS_PROFILE_NAME=<your-profile> ./scripts/run-e2e-full-test.sh \
  --cluster-name openemr-eks-test --aws-region us-west-2 \
  --group backup-restore-inplace --state-file .e2e-test-state \
  --no-timing-report

# List steps / groups
(cd scripts && python3 -m openemr_dr e2e --list-steps)
(cd scripts && python3 -m openemr_dr e2e --list-groups)
```

### Unit tests and CI (no AWS)

**Dependency model:** `versions.yaml` is the source of truth. Pinned lockfiles live in `scripts/requirements/`. CI installs via `scripts/install-python-dev.sh`.

```bash
./scripts/validate-python-requirements.sh openemr_dr   # pins match versions.yaml
./scripts/test-openemr-dr-pinned-versions.sh           # install + import smoke test
./scripts/run-dr-tests.sh                              # full gate: ruff, mypy, bandit, pytest ≥90%
# equivalent:
./scripts/ci/run-python-ci.sh openemr_dr
```

Unit pytest runs use `-m "not floci"` so they stay offline. Floci-marked tests
live in `scripts/openemr_dr/tests/test_floci_aws.py`.

CI jobs **`openemr-dr-ci`**, **`warp-ci`**, **`credential-rotation-ci`**,
**`knowledge-mcp-ci`**, and **`python-requirements-validate`** run on every
push and pull request. Manual `workflow_dispatch` can still select a single
suite. The first three share `scripts/ci/run-python-ci.sh` and
`scripts/install-python-dev.sh`; the knowledge MCP uses its locked `uv`
project.

Shared libraries: `scripts/lib/versions-yq.sh`, `scripts/lib/python-venv.sh`.

Project profiles are declared in `versions.yaml` under **`python_projects`**.

```bash
# Or via main test suite
./scripts/run-test-suite.sh -s script_validation
```

### Floci-backed AWS tests (emulator, not real AWS)

Requires `AWS_ENDPOINT_URL` (CI Floci service or local `tests/floci` compose).
These exercise STS/S3/KMS helpers against the Floci emulator and do **not**
replace the real-AWS end-to-end gate.

```bash
./scripts/run-floci-integration.sh   # includes pytest -m floci for openemr_dr
./scripts/test-floci-e2e-lite.sh     # mocked DR scenario; not END_TO_END gate
```

CI jobs: **`floci-integration`**, **`floci-e2e-lite`**. See
[Testing Guide §6](TESTING_GUIDE.md#6-floci-integration-and-e2e-lite) and
[tests/floci/README.md](../tests/floci/README.md).

### Backup

```bash
cd scripts && python3 -m openemr_dr backup --cluster-name openemr-eks-test
```

## Migration roadmap

The default `preflight` through `verify` phases are native Python. Only the
explicit `legacy` phase uses the Bash bridge
(`RESTORE_INTERNAL=1 restore.sh --bash-only`).

| Component | Status | Next step |
|-----------|--------|-----------|
| Restore phases (preflight→verify) | Native Python | — |
| backup.sh AWS operations | Bash (via `openemr_dr backup`) | Port snapshot/S3/k8s export to Python |
| E2E steps 1–10 | Bash (via runner) | Port one step at a time to `openemr_dr/e2e/steps/` |
| destroy.sh / deploy.sh | Bash subprocess targets | Keep until lower-level APIs exist |

### How to port a phase

1. Add `openemr_dr/restore/phases/<name>.py` with `run(ctx: RestoreContext) -> None`
2. Register in `restore/phases/__init__.py` → `NATIVE`
3. Add tests in `openemr_dr/tests/`
4. Run `./scripts/run-dr-tests.sh`
5. Validate with `--phase <name>` against a dev cluster
6. Remove from `BASH_BRIDGE`

## Terraform restore mode

E2E step 7 applies `-var=skip_rds_creation=true` so RDS is created from the
snapshot in step 8, not as an empty cluster. Step 8 clears `.restore-state`
before invoking the restore so a checkpoint from an earlier environment cannot
skip the RDS phase.

## Related docs

- [Backup & Restore Guide](BACKUP_RESTORE_GUIDE.md)
- [Testing Guide](TESTING_GUIDE.md) (including Floci integration / e2e-lite)
- [End-to-End Testing Requirements](END_TO_END_TESTING_REQUIREMENTS.md)
- [Floci harness README](../tests/floci/README.md)
