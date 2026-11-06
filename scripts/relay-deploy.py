#!/usr/bin/env python3
import argparse
import importlib.util
import json
import os
import time
import urllib.parse
import urllib.request
from pathlib import Path


def api(method, path, body=None):
    base = os.environ["COOLIFY_URL"].rstrip("/")
    if urllib.parse.urlparse(base).scheme != "https":
        raise ValueError("COOLIFY_URL must use HTTPS")
    token = os.environ["COOLIFY_TOKEN"]
    if not token:
        raise ValueError("COOLIFY_TOKEN is not configured")
    request = urllib.request.Request(
        base + "/api/v1" + path,
        data=json.dumps(body).encode() if body is not None else None,
        method=method,
        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def deploy(manifest):
    spec = importlib.util.spec_from_file_location("relay_release", Path(__file__).with_name("relay-release.py"))
    release = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(release)
    release.validate_manifest(manifest, "relay-v" + manifest["version"])
    uuid = os.environ["COOLIFY_APPLICATION_UUID"]
    if not uuid or not uuid.isalnum():
        raise ValueError("Invalid Coolify application UUID")
    path = "/applications/" + uuid
    application = api("GET", path)
    if (application["build_pack"] != "dockercompose"
            or application["git_repository"].lower() != release.repository().lower()
            or application["base_directory"] != "/server/deploy/traefik"):
        raise ValueError("Coolify application is not the expected relay Compose deployment")
    reference = f"{manifest['image']}@{manifest['digest']}"
    environments = api("GET", path + "/envs")
    current = next((entry for entry in environments
                    if entry["key"] == "GOTSYNC_RELAY_IMAGE" and not entry["is_preview"]), None)
    body = {"key": "GOTSYNC_RELAY_IMAGE", "value": reference,
            "is_preview": False, "is_buildtime": False, "is_runtime": True}
    api("PATCH" if current else "POST", path + "/envs", body)
    api("PATCH", path, {
        "git_commit_sha": manifest["revision"], "is_auto_deploy_enabled": False,
        "docker_compose_custom_start_command": f"docker compose --project-name {uuid} up -d --wait --wait-timeout 120",
    })
    response = api("POST", "/deploy", {"uuid": uuid})
    deployment = response["deployments"][0]["deployment_uuid"]
    print(f"Deploying {reference}; Coolify deployment {deployment}", flush=True)
    deadline = time.monotonic() + 600
    while time.monotonic() < deadline:
        state = api("GET", "/deployments/" + deployment)["status"]
        if state == "finished":
            print(f"Stable relay {manifest['version']} deployed successfully")
            return
        if state in {"failed", "cancelled", "canceled"}:
            raise RuntimeError(f"Coolify deployment {deployment} {state}; inspect its deployment log")
        time.sleep(10)
    raise TimeoutError(f"Coolify deployment {deployment} is still pending; inspect it before retrying")


def main():
    parser = argparse.ArgumentParser(description="Pin and deploy a stable relay image in Coolify.")
    parser.add_argument("manifest", type=Path)
    args = parser.parse_args()
    deploy(json.loads(args.manifest.read_text()))


if __name__ == "__main__":
    main()
