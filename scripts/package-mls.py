#!/usr/bin/env python3
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile


root = Path(__file__).resolve().parent.parent
if len(sys.argv) != 2:
    sys.exit("Usage: python3 scripts/package-mls.py OUTPUT_DIRECTORY | --record-inputs | --record-build")
package = root / "Packages/GotSyncMLS"
framework = package / "Artifacts/GotSyncMLSFFI.xcframework"
def hashes(paths, relative_to):
    return {str(path.relative_to(relative_to)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(paths) if path.is_file()}

source_paths = [*root.glob("mls/src/**/*.rs"), *(root / "mls" / name for name in ("Cargo.toml", "Cargo.lock", "uniffi.toml")), root / "scripts/build-mls.sh", root / "scripts/project-env.sh", root / "rust-toolchain.toml"]
build_info = {
    "sources": hashes(source_paths, root),
    "outputs": hashes([*framework.rglob("*"), *package.glob("Sources/GotSyncMLSBindings/*")], package),
}
record_path = package / "Artifacts/build-info.json"
inputs_path = package / "Artifacts/build-inputs.json"
if sys.argv[1] == "--record-inputs":
    inputs_path.parent.mkdir(parents=True, exist_ok=True)
    inputs_path.write_text(json.dumps(build_info["sources"], indent=2) + "\n")
    sys.exit(0)
if sys.argv[1:] == ["--record-build"]:
    if json.loads(inputs_path.read_bytes()) != build_info["sources"]:
        sys.exit("MLS sources changed during the build. Re-run scripts/build-mls.sh.")
    build_info["tools"] = {tool: subprocess.check_output(command, text=True).strip() for tool, command in {
        "rust": ["rustc", "--version"], "swift": ["swift", "--version"], "xcode": ["xcodebuild", "-version"]
    }.items()}
    record_path.write_text(json.dumps(build_info, indent=2) + "\n")
    sys.exit(0)
if not record_path.exists():
    sys.exit("Run scripts/build-mls.sh before packaging to record the binary inputs.")
recorded = json.loads(record_path.read_bytes())
if any(recorded.get(key) != value for key, value in build_info.items()):
    sys.exit("MLS sources or artifacts changed. Run scripts/build-mls.sh before packaging.")
libraries = plistlib.loads((framework / "Info.plist").read_bytes())["AvailableLibraries"]
slices = {(item["SupportedPlatform"], item.get("SupportedPlatformVariant", "")) for item in libraries}
if slices != {("macos", ""), ("ios", ""), ("ios", "simulator")}:
    sys.exit("Run scripts/build-mls.sh to build all Apple slices before packaging.")
output = Path(sys.argv[1]).resolve()
output.mkdir(parents=True, exist_ok=True)
archive = output / "GotSyncMLS.zip"
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
    staging = Path(temporary) / "GotSyncMLS"
    staging.mkdir()
    shutil.copy2(package / "Package.swift", staging)
    shutil.copy2(root / "LICENSE", staging)
    shutil.copy2(record_path, staging)
    for directory in ("Sources", "Tests"):
        shutil.copytree(package / directory, staging / directory)
    shutil.copytree(framework, staging / "Artifacts/GotSyncMLSFFI.xcframework")
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
    inputs = subprocess.check_output(
        ["git", "ls-files", "-z", "mls", "Packages/GotSyncMLS", "scripts/build-mls.sh", "scripts/package-mls.py"], cwd=root
    ).decode().split("\0")
    inputs = sorted(set(inputs) | {"scripts/package-mls.py", "scripts/project-env.sh", "rust-toolchain.toml", "LICENSE"})
    provenance = {
        "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
        "dirty": bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=root)),
        "inputs": {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in inputs if name and (root / name).is_file()},
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
(output / "GotSyncMLS.zip.sha256").write_text(f"{checksum}  {archive.name}\n")
print(archive)
print(checksum)
