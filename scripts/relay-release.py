#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TAG = re.compile(r"relay-v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")
DIGEST = re.compile(r"sha256:[0-9a-f]{64}")


def run(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def gh(*args):
    return json.loads(run("gh", "api", *args))


def repository():
    return os.environ["GITHUB_REPOSITORY"]


def image_name():
    return f"ghcr.io/{repository().lower()}-relay"


def relay_input(path):
    return (path.startswith("server/") and not path.startswith("server/tests/")
            and not path.endswith(".md") and path != "server/.env")


def input_hash(ref="HEAD"):
    entries = run("git", "ls-tree", "-r", ref).splitlines()
    selected = sorted(entry for entry in entries if relay_input(entry.split("\t", 1)[1]))
    if not selected:
        raise ValueError("No relay inputs found")
    return hashlib.sha256("\n".join(selected).encode()).hexdigest()


def releases():
    pages = gh("--paginate", "--slurp", f"repos/{repository()}/releases?per_page=100")
    return [release for page in pages for release in page if TAG.fullmatch(release["tag_name"])]


def tag_order(tag):
    match = TAG.fullmatch(tag)
    if not match:
        raise ValueError("Expected a relay-vMAJOR.MINOR.PATCH tag")
    return tuple(int(value) for value in match.groups())


def load_manifest(tag):
    tag_order(tag)
    with tempfile.TemporaryDirectory() as directory:
        run("gh", "release", "download", tag, "--repo", repository(),
            "--pattern", "relay-release.json", "--dir", directory)
        manifest = json.loads((Path(directory) / "relay-release.json").read_text())
    validate_manifest(manifest, tag)
    return manifest


def validate_manifest(manifest, tag):
    tag_order(tag)
    if manifest.get("schema") != 1 or manifest.get("version") != tag.removeprefix("relay-v"):
        raise ValueError("Unsupported relay manifest or mismatched version")
    if manifest.get("image") != image_name() or not DIGEST.fullmatch(manifest.get("digest", "")):
        raise ValueError("Unexpected relay image or digest")
    if not re.fullmatch(r"[0-9a-f]{40}", manifest.get("revision", "")):
        raise ValueError("Invalid source revision")
    if not re.fullmatch(r"[0-9a-f]{64}", manifest.get("inputs_sha256", "")):
        raise ValueError("Invalid relay input hash")


def require_main():
    if os.environ.get("GITHUB_REF") != "refs/heads/main":
        raise ValueError("Relay releases must run on main")


def require_source(version, revision=None):
    tag = "relay-v" + version
    tag_order(tag)
    require_main()
    revision = revision or run("git", "rev-parse", "HEAD")
    run("git", "fetch", "origin", "main", "--tags")
    run("git", "merge-base", "--is-ancestor", revision, "origin/main")
    runs = gh(f"repos/{repository()}/actions/workflows/ci.yml/runs?head_sha={revision}&event=push&status=success&per_page=1")
    if not any(item["head_branch"] == "main" and item["head_sha"] == revision
               for item in runs["workflow_runs"]):
        raise ValueError("This main commit has no successful CI run; retry after CI passes")
    if run("git", "tag", "--list", tag) and run("git", "rev-parse", f"{tag}^{{commit}}") != revision:
        raise ValueError("This version tag already points to another commit")
    return revision


def release_state(version):
    published = releases()
    tag = "relay-v" + version
    latest = max((item for item in published if not item["draft"]),
                 key=lambda item: tag_order(item["tag_name"]), default=None)
    if latest and tag_order(tag) < tag_order(latest["tag_name"]):
        raise ValueError("Releases cannot move backwards; pin an older digest in Coolify to roll back")
    existing = next((item for item in published if item["tag_name"] == tag), None)
    return latest, existing


def has_manifest(record):
    return any(asset["name"] == "relay-release.json" for asset in record.get("assets", []))


def plan(version, output, force=False):
    require_main()
    tag_order("relay-v" + version)
    latest, existing = release_state(version)
    if existing and (not existing["draft"] or has_manifest(existing)):
        manifest = load_manifest(existing["tag_name"])
        revision = require_source(version, manifest["revision"])
        if manifest["inputs_sha256"] != input_hash(revision):
            raise ValueError("This version records different source inputs")
        Path(output).write_text(json.dumps(manifest, indent=2) + "\n")
        build, publish = False, True
    else:
        revision = require_source(version)
        previous = load_manifest(latest["tag_name"]) if latest else None
        if previous:
            run("git", "merge-base", "--is-ancestor", previous["revision"], revision)
        build = publish = force or previous is None or previous["inputs_sha256"] != input_hash()
    for key, value in {"build": str(build).lower(), "publish": str(publish).lower(),
                       "version": version, "revision": revision, "image": image_name()}.items():
        print(f"{key}={value}")


def image_digest(reference):
    digest = run("docker", "buildx", "imagetools", "inspect", reference,
                 "--format", "{{.Manifest.Digest}}")
    if not DIGEST.fullmatch(digest):
        raise ValueError("Registry returned an invalid digest")
    return digest


def record(version, digest, output):
    revision = require_source(version)
    if not DIGEST.fullmatch(digest) or image_digest(f"{image_name()}:{version}") != digest:
        raise ValueError("Built image tag does not match its digest")
    manifest = {"schema": 1, "version": version, "revision": revision,
                "image": image_name(), "digest": digest, "inputs_sha256": input_hash(),
                "build_url": f"https://github.com/{repository()}/actions/runs/{os.environ['GITHUB_RUN_ID']}"}
    validate_manifest(manifest, "relay-v" + version)
    Path(output).write_text(json.dumps(manifest, indent=2) + "\n")


def publish(manifest):
    version = manifest["version"]
    tag = "relay-v" + version
    validate_manifest(manifest, tag)
    require_source(version, manifest["revision"])
    if input_hash(manifest["revision"]) != manifest["inputs_sha256"]:
        raise ValueError("Release source differs from the built image")
    if image_digest(f"{image_name()}:{version}") != manifest["digest"]:
        raise ValueError("Published image tag differs from its recorded digest")
    _, existing = release_state(version)
    if existing and (not existing["draft"] or has_manifest(existing)):
        if load_manifest(tag) != manifest:
            raise ValueError("This version already records different contents")
        if not existing["draft"]:
            print(f"Reusing {tag}: {image_name()}@{manifest['digest']}")
            return
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "relay-release.json"
        path.write_text(json.dumps(manifest, indent=2) + "\n")
        if not existing:
            notes = Path(directory) / "notes.md"
            notes.write_text(
                f"Relay {version}.\n\nImage: `{image_name()}@{manifest['digest']}`\n\n"
                f"Source: https://github.com/{repository()}/commit/{manifest['revision']}\n\n"
                f"Relay inputs: `{manifest['inputs_sha256']}`.\n")
            run("gh", "release", "create", tag, "--repo", repository(), "--draft",
                "--target", manifest["revision"], "--title", f"Relay {version}",
                "--notes-file", str(notes), "--latest=false")
        run("gh", "release", "upload", tag, str(path), "--repo", repository(), "--clobber")
        run("gh", "release", "edit", tag, "--repo", repository(), "--draft=false", "--target", manifest["revision"], "--latest=false")
    print(f"Published {tag}: {image_name()}@{manifest['digest']}")


def main():
    parser = argparse.ArgumentParser(description="Publish tagged relay versions from tested main commits.")
    sub = parser.add_subparsers(dest="command", required=True)
    select = sub.add_parser("plan")
    select.add_argument("--version", required=True)
    select.add_argument("--output", required=True)
    select.add_argument("--force", action="store_true")
    image = sub.add_parser("record")
    image.add_argument("--version", required=True)
    image.add_argument("--digest", required=True)
    image.add_argument("--output", required=True)
    sub.add_parser("publish").add_argument("manifest", type=Path)
    args = parser.parse_args()
    if args.command == "plan":
        plan(args.version, args.output, args.force)
    elif args.command == "record":
        record(args.version, args.digest, args.output)
    else:
        publish(json.loads(args.manifest.read_text()))


if __name__ == "__main__":
    main()
