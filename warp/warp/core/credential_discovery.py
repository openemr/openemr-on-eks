"""
Automatic credential discovery for OpenEMR
"""

import logging
import subprocess  # nosec B404
import json
import base64
import os
from typing import Optional, Dict

logger = logging.getLogger(__name__)


class CredentialDiscovery:
    """Discover database credentials for direct database import"""

    def __init__(self, namespace: str = "openemr", terraform_dir: Optional[str] = None):
        self.namespace = namespace
        self.terraform_dir = terraform_dir
        self.project_root = os.path.abspath(
            os.path.join(os.path.dirname(__file__), "../../..")
        )
        self.credentials_file_path = os.path.join(
            self.project_root, "k8s", "openemr-credentials.txt"
        )

    def get_db_credentials(self) -> Optional[Dict[str, str]]:
        """Get database credentials for direct DB access"""
        # Try Kubernetes secret first
        try:
            result = subprocess.run(  # nosec B603 B607
                [
                    "kubectl",
                    "get",
                    "secret",
                    "openemr-db-credentials",
                    "-n",
                    self.namespace,
                    "-o",
                    "json",
                ],
                capture_output=True,
                text=True,
                timeout=5,
            )

            if result.returncode == 0:
                secret_data = json.loads(result.stdout)
                data = secret_data.get("data", {})

                host_b64 = data.get("mysql-host", "")
                user_b64 = data.get("mysql-user", "")
                password_b64 = data.get("mysql-password", "")
                database_b64 = data.get("mysql-database", "")

                if host_b64 and user_b64 and password_b64:
                    return {
                        "host": base64.b64decode(host_b64).decode("utf-8"),
                        "user": base64.b64decode(user_b64).decode("utf-8"),
                        "password": base64.b64decode(password_b64).decode("utf-8"),
                        "database": (
                            base64.b64decode(database_b64).decode("utf-8")
                            if database_b64
                            else "openemr"
                        ),
                    }
        except Exception as e:
            logger.debug(f"DB credential discovery failed: {e}")

        # Try Terraform outputs
        if self.terraform_dir:
            try:
                result = subprocess.run(  # nosec B603 B607
                    ["terraform", "-chdir", self.terraform_dir, "output", "-json"],
                    capture_output=True,
                    text=True,
                    timeout=5,
                )
                if result.returncode == 0:
                    outputs = json.loads(result.stdout)
                    # Get DB endpoint from outputs
                    aurora_endpoint = outputs.get("aurora_endpoint", {}).get("value")
                    aurora_password = outputs.get("aurora_password", {}).get("value")
                    if aurora_endpoint and aurora_password:
                        return {
                            "host": aurora_endpoint,
                            "user": "openemr",
                            "password": aurora_password,
                            "database": "openemr",
                        }
            except Exception as e:
                logger.debug(f"Terraform DB credential discovery failed: {e}")

        return None
