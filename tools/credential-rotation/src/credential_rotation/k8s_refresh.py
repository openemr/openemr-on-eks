"""Kubernetes application refresh strategy for credential rotation.

Replaces the ECS-specific ``app_refresh.py`` with Kubernetes equivalents:
  - Update the ``openemr-db-credentials`` Secret with new credentials
  - Trigger a rolling restart of the OpenEMR Deployment
  - Wait for the rollout to complete (pods pass readiness probes)
"""

from __future__ import annotations

import base64
import time
from typing import Any, Dict

from kubernetes import client, config


def _load_k8s_config() -> None:
    """Load kubeconfig -- in-cluster when running as a Job, else local."""
    try:
        config.load_incluster_config()
    except config.ConfigException:
        config.load_kube_config()


def update_k8s_db_secret(
    namespace: str,
    secret_name: str,
    slot: Dict[str, Any],
) -> None:
    """Patch the Kubernetes Secret with the active slot's credentials.

    This ensures that if pods restart independently (OOM, node drain, etc.)
    they pick up the currently-active credentials from the Secret rather than
    stale values.
    """
    _load_k8s_config()
    v1 = client.CoreV1Api()

    patch_body = {
        "data": {
            "mysql-host": base64.b64encode(slot["host"].encode()).decode(),
            "mysql-user": base64.b64encode(slot["username"].encode()).decode(),
            "mysql-password": base64.b64encode(slot["password"].encode()).decode(),
            "mysql-database": base64.b64encode(slot["dbname"].encode()).decode(),
        }
    }

    v1.patch_namespaced_secret(
        name=secret_name,
        namespace=namespace,
        body=patch_body,
    )
    print(f"K8s Secret '{secret_name}' updated in namespace '{namespace}'")


def rollout_restart_deployment(
    namespace: str,
    deployment_name: str,
    timeout_seconds: int = 1800,
) -> None:
    """Trigger a rolling restart and wait for all pods to become ready.

    Equivalent to ``kubectl rollout restart deployment/<name>`` followed
    by ``kubectl rollout status --timeout=<t>``.

    OpenEMR containers need several minutes to start (certificate downloads,
    database connectivity checks, initial setup). Combined with drain time
    for old pods, the full rolling restart can take 15-25 minutes.
    """
    _load_k8s_config()
    apps_v1 = client.AppsV1Api()

    # Annotate the pod template to trigger a rolling restart
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    patch_body = {
        "spec": {
            "template": {
                "metadata": {
                    "annotations": {
                        "credential-rotation/restartedAt": now,
                    }
                }
            }
        }
    }

    apps_v1.patch_namespaced_deployment(
        name=deployment_name,
        namespace=namespace,
        body=patch_body,
    )
    print(f"Rolling restart triggered for deployment '{deployment_name}'")

    _wait_for_rollout(apps_v1, namespace, deployment_name, timeout_seconds)


def _wait_for_rollout(
    apps_v1: client.AppsV1Api,
    namespace: str,
    deployment_name: str,
    timeout_seconds: int,
) -> None:
    """Poll deployment status until the rollout is complete or times out."""
    deadline = time.monotonic() + timeout_seconds
    poll_interval = 15

    while time.monotonic() < deadline:
        dep = apps_v1.read_namespaced_deployment_status(
            name=deployment_name,
            namespace=namespace,
        )
        status = dep.status
        spec_replicas = dep.spec.replicas or 1

        updated = status.updated_replicas or 0
        ready = status.ready_replicas or 0
        available = status.available_replicas or 0

        if updated >= spec_replicas and ready >= spec_replicas and available >= spec_replicas:
            # Verify no old ReplicaSets still have pods
            if (status.unavailable_replicas or 0) == 0:
                print(f"Rollout complete: {ready}/{spec_replicas} pods ready")
                return

        print(f"Rollout in progress: updated={updated} ready={ready} " f"available={available} target={spec_replicas}")
        time.sleep(poll_interval)

    raise RuntimeError(f"Deployment '{deployment_name}' rollout did not complete within {timeout_seconds}s")
