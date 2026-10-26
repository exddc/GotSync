#!/usr/bin/env python3
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile


USAGE = """Usage:
  python3 scripts/package-mls.py OUTPUT_DIRECTORY
  python3 scripts/package-mls.py --pin TAG CHECKSUM
  python3 scripts/package-mls.py --check-pin
  python3 scripts/package-mls.py --record-inputs | --record-build"""
REPOSITORY = "exddc/GotSync"
ARCHIVE = "gotsync_mlsFFI.xcframework.zip"
root = Path(__file__).resolve().parent.parent
framework = root / "Artifacts/gotsync_mlsFFI.xcframework"
bindings = root / "Sources/GotSyncMLSBindings/GotSyncMLSBindings.swift"
manifest = root / "Package.swift"
pin_path = root / "mls/release.json"
record_path = root / "Artifacts/build-info.json"
inputs_path = root / "Artifacts/build-inputs.json"


def hashes(paths):
    return {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(paths) if path.is_file()}


def build_sources():
    return hashes([
        *root.glob("mls/src/**/*.rs"), *(root / "mls" / name for name in ("Cargo.toml", "Cargo.lock", "uniffi.toml")),
        root / "scripts/build-mls.sh", root / "rust-toolchain.toml",
    ])


def release_sources():
    return {**build_sources(), **hashes([bindings])}


def build_outputs():
    return hashes([*framework.rglob("*"), bindings])


def release_url(tag):
    return f"https://github.com/{REPOSITORY}/releases/download/{tag}/{ARCHIVE}"


arguments = sys.argv[1:]
if arguments == ["--record-inputs"]:
    inputs_path.parent.mkdir(parents=True, exist_ok=True)
    inputs_path.write_text(json.dumps(build_sources(), indent=2) + "\n")
    sys.exit(0)
if arguments == ["--record-build"]:
    if json.loads(inputs_path.read_bytes()) != build_sources():
        sys.exit("MLS sources changed during the build. Re-run scripts/build-mls.sh.")
    tools = {tool: subprocess.check_output(command, text=True).strip() for tool, command in {
        "rust": ["rustc", "--version"], "swift": ["swift", "--version"], "xcode": ["xcodebuild", "-version"]
    }.items()}
    record_path.write_text(json.dumps({"sources": build_sources(), "outputs": build_outputs(), "tools": tools}, indent=2) + "\n")
    sys.exit(0)
if len(arguments) == 3 and arguments[0] == "--pin":
    tag, checksum = arguments[1:]
    if not re.fullmatch(r"[0-9a-f]{64}", checksum):
        sys.exit("CHECKSUM must be the 64-character SHA-256 printed by the packaging step.")
    pin_path.write_text(json.dumps({"tag": tag, "checksum": checksum, "sources": release_sources()}, indent=2) + "\n")
    text = manifest.read_text()
    text = re.sub(r'url: "[^"]*"', f'url: "{release_url(tag)}"', text, count=1)
    text = re.sub(r'checksum: "[0-9a-f]{64}"', f'checksum: "{checksum}"', text, count=1)
    manifest.write_text(text)
    sys.exit(0)
if arguments == ["--check-pin"]:
    if not pin_path.exists():
        sys.exit("No MLS binary is pinned. Publish one and pin it as described in CONTRIBUTING.md.")
    pin = json.loads(pin_path.read_bytes())
    text = manifest.read_text()
    if f'url: "{release_url(pin["tag"])}"' not in text or f'checksum: "{pin["checksum"]}"' not in text:
        sys.exit(f"Package.swift does not reference the binary pinned in {pin_path.relative_to(root)}.")
    current = release_sources()
    changed = sorted(name for name in current.keys() | pin["sources"].keys() if current.get(name) != pin["sources"].get(name))
    if changed:
        sys.exit(
            f'MLS inputs changed since {pin["tag"]}: {", ".join(changed)}.\n'
            "Publish a new binary and pin it as described in CONTRIBUTING.md."
        )
    print(f'Package.swift pins {pin["tag"]}, built from the current MLS sources.')
    sys.exit(0)
if len(arguments) != 1 or arguments[0].startswith("--"):
    sys.exit(USAGE)

if not record_path.exists():
    sys.exit("Run scripts/build-mls.sh before packaging to record the binary inputs.")
recorded = json.loads(record_path.read_bytes())
if recorded.get("sources") != build_sources() or recorded.get("outputs") != build_outputs():
    sys.exit("MLS sources or artifacts changed. Run scripts/build-mls.sh before packaging.")
libraries = plistlib.loads((framework / "Info.plist").read_bytes())["AvailableLibraries"]
slices = {(item["SupportedPlatform"], item.get("SupportedPlatformVariant", "")) for item in libraries}
if slices != {("macos", ""), ("ios", ""), ("ios", "simulator")}:
    sys.exit("Run scripts/build-mls.sh without --host-only to build all Apple slices before packaging.")
output = Path(arguments[0]).resolve()
output.mkdir(parents=True, exist_ok=True)
archive = output / ARCHIVE
metadata = json.loads(subprocess.check_output([
    "cargo", "metadata", "--locked", "--format-version", "1", "--manifest-path", str(root / "mls/Cargo.toml")
]))
included = set()
for target in ("aarch64-apple-darwin", "aarch64-apple-ios", "aarch64-apple-ios-sim"):
    tree = subprocess.check_output([
        "cargo", "tree", "--locked", "--manifest-path", str(root / "mls/Cargo.toml"),
        "--target", target, "--edges", "normal,build", "--prefix", "none", "--format", "{p}"
    ], text=True)
    included.update(tuple(line.split()[:2]) for line in tree.splitlines())
with tempfile.TemporaryDirectory(prefix="gotsync-mls-package-") as temporary:
    staging = Path(temporary) / framework.name
    shutil.copytree(framework, staging)
    shutil.copy2(root / "LICENSE", staging)
    shutil.copy2(record_path, staging)
    notices = staging / "ThirdParty"
    notices.mkdir()
    dependencies = []
    workspace_licenses = {}
    for dependency in metadata["packages"]:
        if dependency["source"] is None or (dependency["name"], "v" + dependency["version"]) not in included:
            continue
        if not dependency["source"].startswith("registry+"):
            sys.exit(f'Unsupported dependency source: {dependency["name"]}')
        directory = Path(dependency["manifest_path"]).parent
        destination = notices / f'{dependency["name"]}-{dependency["version"]}'
        destination.mkdir()
        for path in directory.rglob("*"):
            if path.is_file() and path.name.upper().startswith(("LICENSE", "COPYING", "NOTICE", "COPYRIGHT")):
                target = destination / path.relative_to(directory)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, target)
        repository = dependency["repository"] or ""
        vcs = directory / ".cargo_vcs_info.json"
        if not any(destination.iterdir()) and repository.startswith("https://github.com/") and vcs.exists():
            repository = "/".join(repository.removeprefix("https://github.com/").split("/")[:2]).removesuffix(".git")
            revision = json.loads(vcs.read_bytes())["git"]["sha1"]
            workspace_licenses.setdefault((repository, revision), []).append(destination)
        elif not any(destination.iterdir()):
            sys.exit(f'Missing license notices: {dependency["name"]} {dependency["version"]}')
        dependencies.append({
            "name": dependency["name"], "version": dependency["version"],
            "license": dependency["license"], "repository": dependency["repository"],
            "source": f'https://crates.io/api/v1/crates/{dependency["name"]}/{dependency["version"]}/download',
        })
    for repository, revision in sorted(workspace_licenses):
        url = f"https://raw.githubusercontent.com/{repository}/{revision}/LICENSE"
        with urllib.request.urlopen(url, timeout=30) as response:
            license_text = response.read()
            for destination in workspace_licenses[(repository, revision)]:
                (destination / "LICENSE.workspace").write_bytes(license_text)
    (notices / "sources.json").write_text(json.dumps(dependencies, indent=2) + "\n")
    provenance = {
        "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
        "dirty": bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=root)),
        "sources": release_sources(),
        "files": {str(path.relative_to(staging)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(staging.rglob("*")) if path.is_file()},
    }
    (staging / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as bundle:
        for path in sorted(staging.rglob("*")):
            if path.is_file():
                entry = zipfile.ZipInfo(str(path.relative_to(staging.parent)), (1980, 1, 1, 0, 0, 0))
                entry.external_attr = (0o100644 << 16)
                entry.compress_type = zipfile.ZIP_DEFLATED
                bundle.writestr(entry, path.read_bytes())
checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
(output / f"{ARCHIVE}.sha256").write_text(f"{checksum}  {archive.name}\n")
print(archive)
print(checksum)
