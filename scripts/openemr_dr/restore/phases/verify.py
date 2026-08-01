"""Post-restore verification phase."""

from __future__ import annotations

import json
import tempfile
import time
from pathlib import Path

from openemr_dr import config
from openemr_dr.common import log
from openemr_dr.common.paths import K8S_DIR, TERRAFORM_DIR
from openemr_dr.common.shell import run as run_cmd
from openemr_dr.errors import PhaseError
from openemr_dr.models.restore import RestoreContext

HPA_NAME = "openemr-hpa"
CRYPTO_KEY_PATH = (
    "/var/www/localhost/htdocs/openemr/sites/default/documents/logs_and_misc/methods/"
)


def _normalize_replica_count(raw: str) -> int:
    value = raw.strip()
    if not value.isdigit():
        return 0
    return int(value)


def _deployment_replicas(namespace: str) -> tuple[int, int]:
    ready_raw = run_cmd(
        [
            "kubectl",
            "get",
            "deployment",
            "openemr",
            "-n",
            namespace,
            "-o",
            "jsonpath={.status.readyReplicas}",
        ],
        capture=True,
        check=False,
    )
    desired_raw = run_cmd(
        [
            "kubectl",
            "get",
            "deployment",
            "openemr",
            "-n",
            namespace,
            "-o",
            "jsonpath={.spec.replicas}",
        ],
        capture=True,
        check=False,
    )
    return _normalize_replica_count(ready_raw.stdout or ""), _normalize_replica_count(desired_raw.stdout or "")


def _running_pod(namespace: str) -> str:
    result = run_cmd(
        [
            "kubectl",
            "get",
            "pods",
            "-n",
            namespace,
            "-l",
            "app=openemr",
            "--field-selector=status.phase=Running",
            "-o",
            "jsonpath={.items[0].metadata.name}",
        ],
        capture=True,
        check=False,
    )
    return (result.stdout or "").strip()


def _pod_is_ready(namespace: str, pod: str) -> bool:
    ready = run_cmd(
        [
            "kubectl",
            "get",
            "pod",
            pod,
            "-n",
            namespace,
            "-o",
            "jsonpath={.status.conditions[?(@.type==\"Ready\")].status}",
        ],
        capture=True,
        check=False,
    )
    return (ready.stdout or "").strip() == "True"


def _pod_serves_http(namespace: str, pod: str) -> bool:
    probe = run_cmd(
        [
            "kubectl",
            "exec",
            "-n",
            namespace,
            pod,
            "-c",
            "openemr",
            "--",
            "curl",
            "-s",
            "-f",
            "http://localhost/interface/login/login.php",
        ],
        check=False,
    )
    return probe.returncode == 0


def openemr_pod_is_healthy(namespace: str) -> bool:
    pod = _running_pod(namespace)
    if not pod:
        return False
    if not _pod_is_ready(namespace, pod):
        return False
    return _pod_serves_http(namespace, pod)


def prepare_single_replica(ctx: RestoreContext) -> None:
    """Scale to one replica and remove HPA for stable verification."""
    log.step("Preparing single-replica verification mode")
    run_cmd(
        ["kubectl", "delete", "hpa", HPA_NAME, "-n", ctx.namespace, "--ignore-not-found"],
        check=False,
    )
    exists = run_cmd(
        ["kubectl", "get", "deployment", "openemr", "-n", ctx.namespace],
        check=False,
    )
    if exists.returncode == 0:
        run_cmd(["kubectl", "scale", "deployment", "openemr", "-n", ctx.namespace, "--replicas=1"])
        run_cmd(
            [
                "kubectl",
                "rollout",
                "status",
                "deployment/openemr",
                "-n",
                ctx.namespace,
                f"--timeout={config.POD_READY_WAIT_TIMEOUT}s",
            ],
            check=False,
        )
    log.success("Single-replica mode ready")


def restore_autoscaling(ctx: RestoreContext) -> None:
    """Render the pristine HPA template and apply it after verification."""
    hpa_file = K8S_DIR / "hpa.yaml"
    if not hpa_file.exists():
        raise PhaseError("verify", f"HPA template missing: {hpa_file}")

    config_result = run_cmd(
        ["terraform", "output", "-json", "openemr_autoscaling_config"],
        cwd=str(TERRAFORM_DIR),
        capture=True,
        check=False,
    )
    if config_result.returncode != 0:
        raise PhaseError("verify", "Unable to read Terraform autoscaling configuration")
    try:
        autoscaling = json.loads(config_result.stdout or "")
    except json.JSONDecodeError as exc:
        raise PhaseError("verify", "Terraform autoscaling configuration is invalid JSON") from exc
    if not isinstance(autoscaling, dict):
        raise PhaseError("verify", "Terraform autoscaling configuration is not an object")

    replacements = {
        "${OPENEMR_MIN_REPLICAS}": autoscaling.get("min_replicas"),
        "${OPENEMR_MAX_REPLICAS}": autoscaling.get("max_replicas"),
        "${OPENEMR_CPU_THRESHOLD}": autoscaling.get("cpu_utilization_threshold"),
        "${OPENEMR_MEMORY_THRESHOLD}": autoscaling.get("memory_utilization_threshold"),
        "${OPENEMR_SCALE_DOWN_STABILIZATION}": autoscaling.get(
            "scale_down_stabilization_seconds"
        ),
        "${OPENEMR_SCALE_UP_STABILIZATION}": autoscaling.get(
            "scale_up_stabilization_seconds"
        ),
    }
    missing = [placeholder for placeholder, value in replacements.items() if value is None]
    if missing:
        raise PhaseError(
            "verify",
            f"Terraform autoscaling configuration is missing values for: {', '.join(missing)}",
        )

    rendered = hpa_file.read_text(encoding="utf-8")
    rendered = rendered.replace("  namespace: openemr", f"  namespace: {ctx.namespace}")
    for placeholder, value in replacements.items():
        rendered = rendered.replace(placeholder, str(value))
    if "${OPENEMR_" in rendered:
        raise PhaseError("verify", "Rendered HPA manifest still contains placeholders")

    log.info("Re-applying HPA")
    rendered_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            "w",
            encoding="utf-8",
            suffix=".yaml",
            prefix="openemr-hpa.",
            delete=False,
        ) as stream:
            stream.write(rendered)
            rendered_path = Path(stream.name)
        apply_result = run_cmd(
            ["kubectl", "apply", "-f", str(rendered_path)],
            check=False,
        )
    finally:
        if rendered_path is not None:
            rendered_path.unlink(missing_ok=True)
    if apply_result.returncode != 0:
        raise PhaseError("verify", "Failed to restore HPA after verification")
    log.success("HPA restored")


def cleanup_crypto_keys(ctx: RestoreContext) -> None:
    log.step("Cleaning crypto key cache files")
    time.sleep(10)
    pods_raw = run_cmd(
        [
            "kubectl",
            "get",
            "pods",
            "-n",
            ctx.namespace,
            "-l",
            "app=openemr",
            "-o",
            "jsonpath={.items[*].metadata.name}",
        ],
        capture=True,
        check=False,
    )
    pods = (pods_raw.stdout or "").split()
    if not pods:
        log.warning("No OpenEMR pods found for crypto cleanup")
        return
    delete_cmd = f"find {CRYPTO_KEY_PATH} -name '*six*' -type f -delete 2>/dev/null || true"
    for pod in pods:
        run_cmd(
            [
                "kubectl",
                "exec",
                "-n",
                ctx.namespace,
                pod,
                "-c",
                "openemr",
                "--",
                "sh",
                "-c",
                delete_cmd,
            ],
            check=False,
        )
    time.sleep(30)
    log.success("Crypto key cleanup complete")


def verify_once(ctx: RestoreContext) -> bool:
    elapsed = 0
    while elapsed < config.VERIFICATION_TIMEOUT:
        ready, desired = _deployment_replicas(ctx.namespace)
        if desired == 0:
            return False
        if ready >= 1 and openemr_pod_is_healthy(ctx.namespace):
            log.success(f"Restore verified: {ready}/{desired} pod(s) ready and serving HTTP")
            return True
        log.info(f"Pods: {ready}/{desired} ready (elapsed {elapsed}s)")
        time.sleep(config.VERIFICATION_INTERVAL)
        elapsed += config.VERIFICATION_INTERVAL
    return False


def run(ctx: RestoreContext) -> None:
    if ctx.dry_run:
        log.info("[dry-run] Would verify restore success")
        return

    log.step("Verifying restore success")
    for attempt in range(1, config.VERIFICATION_MAX_ATTEMPTS + 1):
        log.info(f"Verification attempt {attempt}/{config.VERIFICATION_MAX_ATTEMPTS}")
        if verify_once(ctx):
            restore_autoscaling(ctx)
            return
        if attempt < config.VERIFICATION_MAX_ATTEMPTS:
            cleanup_crypto_keys(ctx)
    ready, desired = _deployment_replicas(ctx.namespace)
    raise PhaseError(
        "verify",
        f"Verification failed after {config.VERIFICATION_MAX_ATTEMPTS} attempts "
        f"({ready}/{desired} pods ready)",
    )
