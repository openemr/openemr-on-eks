"""Floci-backed S3 integration tests for OMOPToCCDAConverter."""

from __future__ import annotations

import os

import boto3
import pytest

from warp.core.omop_to_ccda import OMOPToCCDAConverter

pytestmark = pytest.mark.floci


def _require_floci() -> str:
    endpoint = os.environ.get("AWS_ENDPOINT_URL", "").strip()
    if not endpoint:
        pytest.skip("AWS_ENDPOINT_URL unset (Floci not configured)")
    return endpoint


@pytest.fixture()
def floci_s3_bucket() -> str:
    _require_floci()
    region = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")
    bucket = os.environ.get("FLOCI_WARP_BUCKET") or f"openemr-floci-warp-{os.getpid()}"
    client = boto3.client("s3", region_name=region)
    try:
        client.head_bucket(Bucket=bucket)
    except Exception:
        client.create_bucket(Bucket=bucket)
    # Minimal person CSV for converter load path
    body = "person_id,gender_concept_id,year_of_birth\n1,8507,1980\n"
    key = "omop/person.csv"
    client.put_object(Bucket=bucket, Key=key, Body=body.encode("utf-8"))
    return bucket


def test_floci_converter_loads_person_csv_from_s3(floci_s3_bucket: str) -> None:
    _require_floci()
    conv = OMOPToCCDAConverter(
        data_source=f"s3://{floci_s3_bucket}/omop",
        aws_region=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"),
    )
    rows = conv._load_from_s3("person")
    assert len(rows) == 1
    assert rows[0]["person_id"] == "1"


def test_floci_s3_work_bucket_put_get() -> None:
    endpoint = _require_floci()
    region = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")
    bucket = os.environ.get("FLOCI_WORK_BUCKET") or f"openemr-floci-work-{os.getpid()}"
    client = boto3.client("s3", region_name=region, endpoint_url=endpoint)
    try:
        client.head_bucket(Bucket=bucket)
    except Exception:
        client.create_bucket(Bucket=bucket)

    key = "reports/floci-smoke.txt"
    body = b"warp-floci-work-ok"
    client.put_object(Bucket=bucket, Key=key, Body=body)
    got = client.get_object(Bucket=bucket, Key=key)["Body"].read()
    assert got == body
