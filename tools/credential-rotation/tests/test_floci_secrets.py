"""Floci-backed Secrets Manager integration tests for credential rotation."""

from __future__ import annotations

import json
import os

import boto3
import pytest

from credential_rotation.secrets_manager import SecretsManagerSlots

pytestmark = pytest.mark.floci


def _require_floci() -> None:
    if not os.environ.get("AWS_ENDPOINT_URL", "").strip():
        pytest.skip("AWS_ENDPOINT_URL unset (Floci not configured)")


def test_floci_secrets_manager_slots_round_trip() -> None:
    _require_floci()
    region = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")
    secret_name = os.environ.get("FLOCI_SLOT_SECRET_NAME", "openemr/floci/rds-slots")

    client = boto3.client("secretsmanager", region_name=region)
    payload = {
        "active_slot": "A",
        "A": {"username": "openemr", "password": "slot-a-password"},
        "B": {"username": "openemr", "password": "slot-b-password"},
    }
    try:
        client.describe_secret(SecretId=secret_name)
        client.put_secret_value(SecretId=secret_name, SecretString=json.dumps(payload))
    except client.exceptions.ResourceNotFoundException:
        client.create_secret(Name=secret_name, SecretString=json.dumps(payload))

    slots = SecretsManagerSlots(region=region)
    state = slots.get_secret(secret_name)
    assert state.active_slot == "A"
    assert state.slot("A")["password"] == "slot-a-password"

    updated = dict(state.payload)
    updated["active_slot"] = "B"
    updated["B"] = {"username": "openemr", "password": "rotated-b"}
    slots.put_payload(secret_name, updated)

    refreshed = slots.get_secret(secret_name)
    assert refreshed.active_slot == "B"
    assert refreshed.slot("B")["password"] == "rotated-b"
