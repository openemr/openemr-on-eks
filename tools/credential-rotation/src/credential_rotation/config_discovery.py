"""Runtime config discovery for OpenEMR-on-EKS deployment."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class RuntimeConfigPaths:
    """Resolved runtime paths used by the rotation process."""

    sqlconf_path: Path


def discover_runtime_paths(sites_mount_root: str) -> RuntimeConfigPaths:
    """Discover runtime paths without relying on guessed directories.

    The repository deploys OpenEMR sites to
    `/var/www/localhost/htdocs/openemr/sites/` via EFS.  The rotation Job
    mounts that EFS path at an explicit mountpoint.
    """

    sites_root = Path(sites_mount_root)
    sqlconf_path = sites_root / "default" / "sqlconf.php"
    if not sqlconf_path.exists():
        raise FileNotFoundError(f"OpenEMR sqlconf.php not found at discovered path: {sqlconf_path}")

    return RuntimeConfigPaths(sqlconf_path=sqlconf_path)
