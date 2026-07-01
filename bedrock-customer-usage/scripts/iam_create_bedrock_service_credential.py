#!/usr/bin/env python3
"""Create a Bedrock service-specific credential through IAM Query API.

Some AWS CLI/botocore builds lag the Bedrock API-key fields. This helper uses
the public IAM Query API directly so callers can set CredentialAgeDays and read
the one-time ServiceApiKeyValue from the raw XML response.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import hmac
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET


def sign(key: bytes, msg: str) -> bytes:
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()


def local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--user-name", required=True)
    parser.add_argument("--credential-age-days", required=True, type=int)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    access_key = os.environ.get("AWS_ACCESS_KEY_ID")
    secret_key = os.environ.get("AWS_SECRET_ACCESS_KEY")
    session_token = os.environ.get("AWS_SESSION_TOKEN")

    if not access_key or not secret_key:
        print("AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY are required", file=sys.stderr)
        return 2

    method = "POST"
    service = "iam"
    region = "us-east-1"
    host = "iam.amazonaws.com"
    endpoint = f"https://{host}/"
    body = urllib.parse.urlencode(
        {
            "Action": "CreateServiceSpecificCredential",
            "Version": "2010-05-08",
            "UserName": args.user_name,
            "ServiceName": "bedrock.amazonaws.com",
            "CredentialAgeDays": str(args.credential_age_days),
        }
    )

    now = dt.datetime.now(dt.timezone.utc)
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    date_stamp = now.strftime("%Y%m%d")
    headers = {
        "content-type": "application/x-www-form-urlencoded; charset=utf-8",
        "host": host,
        "x-amz-date": amz_date,
    }
    if session_token:
        headers["x-amz-security-token"] = session_token

    canonical_headers = "".join(f"{key}:{headers[key]}\n" for key in sorted(headers))
    signed_headers = ";".join(sorted(headers))
    payload_hash = hashlib.sha256(body.encode("utf-8")).hexdigest()
    canonical_request = "\n".join(
        [method, "/", "", canonical_headers, signed_headers, payload_hash]
    )
    algorithm = "AWS4-HMAC-SHA256"
    credential_scope = f"{date_stamp}/{region}/{service}/aws4_request"
    string_to_sign = "\n".join(
        [
            algorithm,
            amz_date,
            credential_scope,
            hashlib.sha256(canonical_request.encode("utf-8")).hexdigest(),
        ]
    )
    signing_key = sign(
        sign(
            sign(sign(("AWS4" + secret_key).encode("utf-8"), date_stamp), region),
            service,
        ),
        "aws4_request",
    )
    signature = hmac.new(
        signing_key, string_to_sign.encode("utf-8"), hashlib.sha256
    ).hexdigest()
    authorization = (
        f"{algorithm} Credential={access_key}/{credential_scope}, "
        f"SignedHeaders={signed_headers}, Signature={signature}"
    )
    request_headers = {key.title(): value for key, value in headers.items()}
    request_headers["Authorization"] = authorization

    request = urllib.request.Request(
        endpoint,
        data=body.encode("utf-8"),
        headers=request_headers,
        method=method,
    )

    try:
        response = urllib.request.urlopen(request, timeout=60)
        xml_data = response.read()
    except urllib.error.HTTPError as exc:
        print(exc.read().decode("utf-8", errors="replace"), file=sys.stderr)
        return 1

    root = ET.fromstring(xml_data)
    values: dict[str, str] = {}
    for elem in root.iter():
        text = elem.text.strip() if elem.text else ""
        if text:
            values[local_name(elem.tag)] = text

    secret = (
        values.get("ServiceApiKeyValue")
        or values.get("ServiceCredentialSecret")
        or values.get("ServicePassword")
    )
    if not secret:
        print(
            "CreateServiceSpecificCredential response did not include a bearer token",
            file=sys.stderr,
        )
        print(xml_data.decode("utf-8", errors="replace"), file=sys.stderr)
        return 1

    print(
        json.dumps(
            {
                "ServiceSpecificCredential": {
                    "ServiceSpecificCredentialId": values.get(
                        "ServiceSpecificCredentialId", ""
                    ),
                    "ServiceName": values.get("ServiceName", "bedrock.amazonaws.com"),
                    "ServiceUserName": values.get("ServiceUserName", ""),
                    "UserName": values.get("UserName", args.user_name),
                    "Status": values.get("Status", ""),
                    "CreateDate": values.get("CreateDate", ""),
                    "ExpirationDate": values.get("ExpirationDate", ""),
                    "ServiceApiKeyValue": secret,
                }
            }
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
