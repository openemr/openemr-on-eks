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
