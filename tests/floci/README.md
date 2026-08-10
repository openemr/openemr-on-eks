# Floci Test Harness

Local AWS emulator helpers for Floci-backed CI suites.

Routine validation runs in GitHub Actions (`floci-integration` and `floci-e2e-lite` jobs).
Use this directory only when reproducing a CI failure locally.

## Prerequisites

- Docker and Docker Compose
- AWS CLI v2
- `curl`, `jq` (optional `yq` to read the pin from `versions.yaml`)

## Start Floci

```bash
# Optional: align image tag with versions.yaml
export FLOCI_VERSION="$(yq eval '.applications.floci.current' versions.yaml)"

docker compose -f tests/floci/compose.yaml up -d
./tests/floci/wait.sh
source tests/floci/env.sh
./tests/floci/seed.sh
```

## Run suites

```bash
# BATS smoke (requires AWS_ENDPOINT_URL from env.sh)
bats tests/bats/floci-smoke.bats

# Python Floci-marked tests
uv run --project warp pytest -m floci warp/tests
uv run --project tools/credential-rotation pytest -m floci tools/credential-rotation/tests
uv run --project scripts/openemr_dr pytest -m floci scripts/openemr_dr/tests

# e2e-lite DR scenario mock
./scripts/test-floci-e2e-lite.sh
```

## Stop

```bash
docker compose -f tests/floci/compose.yaml down
```

## Notes

- Floci e2e-lite mocks the DR *scenario* (S3/KMS/Secrets/RDS API shapes). It does **not** replace the real-AWS gate in `docs/END_TO_END_TESTING_REQUIREMENTS.md`.
- Image pin lives in `versions.yaml` under `applications.floci` and is tracked by the monthly version-check workflow.
- Do not set `read_only: true` or `cap_drop: ALL` on the Floci service — the native server needs writable runtime state and will time out in `wait.sh` otherwise.
- `wait.sh` defaults to a 180s timeout and dumps compose logs on failure. Override with `FLOCI_WAIT_TIMEOUT`.

## Related documentation

- [Testing Guide §6 — Floci Integration and E2E Lite](../../docs/TESTING_GUIDE.md#6-floci-integration-and-e2e-lite)
- [End-to-End Testing Requirements](../../docs/END_TO_END_TESTING_REQUIREMENTS.md) (real-AWS gate)
- [Version Management — Floci pin](../../docs/VERSION_MANAGEMENT.md#floci-local-aws-emulator)
- [Scripts README — Floci runners](../../scripts/README.md#run-floci-integrationsh)
- [Tests README](../README.md)
- [CI/CD workflows README](../../.github/workflows/README.md)
