#!/usr/bin/env python3
"""Create/update an App Store version and submit it for review."""

from __future__ import annotations

import argparse
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils


BASE_URL = "https://api.appstoreconnect.apple.com"
DEFAULT_WHATS_NEW = (
    "Fixed remote discovery for services that start after Web Finder is already running. "
    "Devices now re-sync Tailscale Serve mappings during manifest refreshes, so newly "
    "started services appear across your tailnet without restarting Web Finder.\n\n"
    "Also fixes the build label shown in App Store release builds."
)


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def jwt_token() -> str:
    key_path = os.environ.get("APP_STORE_CONNECT_KEY_PATH")
    key_id = os.environ.get("APP_STORE_CONNECT_KEY_ID")
    issuer_id = os.environ.get("APP_STORE_CONNECT_ISSUER_ID")
    if not key_path or not key_id or not issuer_id:
        raise SystemExit(
            "Set APP_STORE_CONNECT_KEY_PATH, APP_STORE_CONNECT_KEY_ID, and "
            "APP_STORE_CONNECT_ISSUER_ID."
        )

    private_key = serialization.load_pem_private_key(Path(key_path).read_bytes(), password=None)
    now = int(time.time())
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    payload = {
        "iss": issuer_id,
        "iat": now,
        "exp": now + 20 * 60,
        "aud": "appstoreconnect-v1",
    }
    signing_input = (
        b64url(json.dumps(header, separators=(",", ":")).encode())
        + "."
        + b64url(json.dumps(payload, separators=(",", ":")).encode())
    ).encode()
    der_signature = private_key.sign(signing_input, ec.ECDSA(hashes.SHA256()))
    r, s = utils.decode_dss_signature(der_signature)
    raw_signature = r.to_bytes(32, "big") + s.to_bytes(32, "big")
    return signing_input.decode() + "." + b64url(raw_signature)


def request(method: str, path: str, data: dict | None = None) -> dict:
    body = None if data is None else json.dumps(data).encode()
    req = urllib.request.Request(
        BASE_URL + path,
        data=body,
        method=method,
        headers={
            "Authorization": f"Bearer {jwt_token()}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as response:
            return json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as exc:
        details = exc.read().decode()
        print(f"{method} {path} failed: HTTP {exc.code}", file=sys.stderr)
        print(details, file=sys.stderr)
        raise


def find_app_id(bundle_id: str) -> str:
    query = urllib.parse.urlencode({"filter[bundleId]": bundle_id})
    apps = request("GET", f"/v1/apps?{query}")["data"]
    if not apps:
        raise SystemExit(f"No App Store Connect app found for bundle id {bundle_id}")
    return apps[0]["id"]


def get_or_create_version(app_id: str, version: str) -> str:
    versions = request("GET", f"/v1/apps/{app_id}/appStoreVersions")["data"]
    for item in versions:
        attrs = item["attributes"]
        if attrs.get("platform") == "IOS" and attrs.get("versionString") == version:
            return item["id"]

    payload = {
        "data": {
            "type": "appStoreVersions",
            "attributes": {"platform": "IOS", "versionString": version},
            "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
        }
    }
    return request("POST", "/v1/appStoreVersions", payload)["data"]["id"]


def latest_eligible_build(app_id: str, build_number: str | None) -> str:
    params = {"filter[app]": app_id, "sort": "-uploadedDate", "limit": "50"}
    if build_number:
        params["filter[version]"] = build_number
    builds = request("GET", f"/v1/builds?{urllib.parse.urlencode(params)}")["data"]
    for build in builds:
        attrs = build["attributes"]
        if (
            attrs.get("processingState") == "VALID"
            and attrs.get("buildAudienceType") == "APP_STORE_ELIGIBLE"
        ):
            return build["id"]
    raise SystemExit("No VALID App Store-eligible build found.")


def attach_build(version_id: str, build_id: str) -> None:
    request(
        "PATCH",
        f"/v1/appStoreVersions/{version_id}/relationships/build",
        {"data": {"type": "builds", "id": build_id}},
    )


def update_whats_new(version_id: str, whats_new: str) -> None:
    locs = request("GET", f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations")[
        "data"
    ]
    loc = next((item for item in locs if item["attributes"].get("locale") == "en-US"), None)
    if not loc:
        payload = {
            "data": {
                "type": "appStoreVersionLocalizations",
                "attributes": {"locale": "en-US"},
                "relationships": {
                    "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}}
                },
            }
        }
        loc = request("POST", "/v1/appStoreVersionLocalizations", payload)["data"]
    request(
        "PATCH",
        f"/v1/appStoreVersionLocalizations/{loc['id']}",
        {
            "data": {
                "type": "appStoreVersionLocalizations",
                "id": loc["id"],
                "attributes": {"whatsNew": whats_new},
            }
        },
    )


def submit(version_id: str, app_id: str) -> str:
    submission = request(
        "POST",
        "/v1/reviewSubmissions",
        {
            "data": {
                "type": "reviewSubmissions",
                "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
            }
        },
    )["data"]
    submission_id = submission["id"]
    request(
        "POST",
        "/v1/reviewSubmissionItems",
        {
            "data": {
                "type": "reviewSubmissionItems",
                "relationships": {
                    "reviewSubmission": {
                        "data": {"type": "reviewSubmissions", "id": submission_id}
                    },
                    "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}},
                },
            }
        },
    )
    response = request(
        "PATCH",
        f"/v1/reviewSubmissions/{submission_id}",
        {
            "data": {
                "type": "reviewSubmissions",
                "id": submission_id,
                "attributes": {"submitted": True},
            }
        },
    )
    return response["data"]["attributes"]["state"]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("version")
    parser.add_argument("--bundle-id", default="com.zeulewan.WebFinder")
    parser.add_argument("--build-number", help="Specific App Store Connect build number to use")
    parser.add_argument("--whats-new", default=DEFAULT_WHATS_NEW)
    parser.add_argument("--no-submit", action="store_true")
    args = parser.parse_args()

    app_id = find_app_id(args.bundle_id)
    version_id = get_or_create_version(app_id, args.version)
    build_id = latest_eligible_build(app_id, args.build_number)
    attach_build(version_id, build_id)
    update_whats_new(version_id, args.whats_new)

    if args.no_submit:
        print(f"Prepared {args.version}: version={version_id} build={build_id}")
        return

    state = submit(version_id, app_id)
    print(f"Submitted {args.version}: version={version_id} build={build_id} state={state}")


if __name__ == "__main__":
    main()
