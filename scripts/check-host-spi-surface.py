#!/usr/bin/env python3
"""Checks the HostJournalPreview and BlobPreview SPI surfaces of GotSync through its symbol graph.

The surface is the set of SPI symbols plus every symbol inside an SPI type.
It must equal the reviewed set of types and engine members of each group, and
no surface declaration may name a storage, writer, SQLite, MLS, relay-client,
codec or test-hook type.
Pre-existing public API outside the surface is not inspected.

Usage: check-host-spi-surface.py [--graph-dir DIR]
Without --graph-dir the graph is extracted from the built GotSync module.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SPI_GROUPS = {"HostJournalPreview", "BlobPreview"}

SURFACE_TYPES = {
    "HostJournal",
    "HostJournalView",
    "HostJournalState",
    "HostJournalLifecycle",
    "HostClosingIntent",
    "HostEnrollmentState",
    "HostIntakeState",
    "HostRetirementReason",
    "HostProvenance",
    "HostMutation",
    "HostMutationID",
    "HostRecordID",
    "JournalPosition",
    "IncomingRecord",
    "HostJournalError",
    "HostJournalRepair",
    "HostJournalCapacity",
    "HostJournalArchive",
    "HostArchiveItem",
    "HostQuarantineReason",
    "HostArchiveCursor",
    "HostArchivePage",
    "HostSubmissionLimits",
}

BLOB_SURFACE_TYPES = {
    "BlobTransferService",
    "BlobTransferID",
    "BlobRoute",
    "BlobCapacity",
    "BlobError",
    "BlobOutgoingFailure",
    "BlobOutgoingStatus",
    "BlobRejection",
    "BlobIncomingStatus",
    "BlobSummary",
    "BlobImageInfo",
    "BlobDescriptorInfo",
    "BlobDataDescriptorInfo",
    "BlobContentKind",
    "BlobHostHooks",
}

REQUIRED_BLOB_CALLS = {
    "maximumObjectPlaintextLength",
    "seal(_:route:source:expectedContentHash:)",
    "sealData(_:route:source:expectedContentHash:)",
    "requestIncomingData(_:route:descriptor:)",
    "registerAvailableData(route:descriptor:)",
    "outgoing()",
    "confirmHandoff(_:descriptorDigest:)",
    "cancelOutgoing(_:)",
    "requestIncoming(_:route:descriptor:)",
    "incoming()",
    "confirmPublished(_:descriptorDigest:)",
    "cancelIncoming(_:)",
    "registerAvailable(route:descriptor:)",
    "unregisterAvailable(route:objectID:)",
    "release(route:objectIDs:)",
    "summary()",
    "summary(for:)",
    "setHooks(_:)",
    "updates()",
}

SURFACE_MEMBERS = {
    "SyncEngine": {
        "hostJournal",
        "hostJournalView",
        "hostViewChanges()",
        "hostJournalArchives()",
        "exportHostJournal(_:after:limit:)",
        "discardRetiredHostJournal(_:confirmingJournalID:)",
        "blobTransfers()",
    },
    "SyncPayloadSchema": {"hostJournal(payload:version:)"},
    "Invitation": {"phraseWordCount"},
}

REQUIRED_HOST_CALLS = {
    "journalID",
    "group",
    "enroll()",
    "resume(_:)",
    "submit(_:capturedThrough:)",
    "incoming(after:limit:)",
    "markApplied(through:)",
    "declareReady(capturedThrough:)",
    "submissionLimits",
}

FORBIDDEN_NAMES = re.compile(
    r"HostJournalStore|HostJournalWriter|HostJournalSnapshot|HostJournalFiles|HostEngineView|"
    r"JournalDatabase|JournalStoreError|\bJournalCapacity\b|JournalValue|HostJournalListing|"
    r"HostJournalExport|HostJournalProvenance|OpaquePointer|SQLite|sqlite3|MLSSession|MLSClient|"
    r"MLSStore|ForTesting|forTesting|BlobStateStore|BlobFiles|BlobRelayClient|BlobRelayError|BlobCipher|"
    r"BlobSealedObject|BlobManifest|BlobPartLayout|\bBlobDescriptor\b|\bBlobBinding\b|BlobWorkGate|BlobSignal|"
    r"BlobCodecError|BlobImageValidator"
)
FORBIDDEN_MODULE_PREFIXES = ("s:10GotSyncMLS", "s:18GotSyncMLSBindings", "c:@")


def fail(problems):
    for problem in problems:
        print(f"SPI surface: {problem}", file=sys.stderr)
    sys.exit(1)


def source_spi_groups():
    groups = set()
    for path in (ROOT / "Sources").rglob("*.swift"):
        groups.update(re.findall(r"@_spi\((\w+)\)", path.read_text()))
    return groups


def dump_graph():
    # `swift package dump-symbol-graph` drops SPI symbols, so the graph is
    # extracted from the built module directly.
    scratch = os.environ.get("GOTSYNC_SWIFT_SCRATCH_PATH")
    build = ["swift", "build", "--target", "GotSync"] + (["--scratch-path", scratch] if scratch else [])
    subprocess.run(build, cwd=ROOT, check=True, capture_output=True, text=True)
    products = Path(subprocess.run(build + ["--show-bin-path"], cwd=ROOT, check=True, capture_output=True, text=True).stdout.strip())
    sdk = subprocess.run(["xcrun", "--show-sdk-path", "--sdk", "macosx"], check=True, capture_output=True, text=True).stdout.strip()
    output = Path(tempfile.mkdtemp())
    subprocess.run([
        "xcrun", "swift", "symbolgraph-extract", "-module-name", "GotSync",
        "-I", str(products), "-F", str(products), "-F", str(products / "PackageFrameworks"),
        "-Xcc", f"-fmodule-map-file={products / 'include/module.modulemap'}",
        "-target", "arm64-apple-macos14.0", "-sdk", sdk,
        "-minimum-access-level", "public", "-include-spi-symbols", "-skip-synthesized-members",
        "-output-dir", str(output),
    ], cwd=ROOT, check=True, capture_output=True, text=True)
    return output


def load(graph_dir):
    symbols, relationships = {}, []
    files = sorted(graph_dir.glob("GotSync.symbols.json")) + sorted(graph_dir.glob("GotSync@*.symbols.json"))
    if not files:
        fail([f"no GotSync symbol graph in {graph_dir}"])
    for path in files:
        graph = json.loads(path.read_text())
        for symbol in graph["symbols"]:
            symbols[symbol["identifier"]["precise"]] = symbol
        relationships += graph.get("relationships", [])
    return symbols, relationships


def fragments(symbol):
    found = list(symbol.get("declarationFragments", []))
    signature = symbol.get("functionSignature", {})
    for parameter in signature.get("parameters", []):
        found += parameter.get("declarationFragments", [])
    found += signature.get("returns", [])
    return found


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--graph-dir", type=Path)
    arguments = parser.parse_args()
    problems = []

    extra_groups = source_spi_groups() - SPI_GROUPS
    if extra_groups:
        problems.append(f"unexpected SPI groups {sorted(extra_groups)}")

    symbols, relationships = load(arguments.graph_dir or dump_graph())
    if not any(symbol.get("spi") for symbol in symbols.values()):
        fail(["the graph carries no SPI symbols; was --include-spi-symbols honored?"])

    surface = {}
    for precise, symbol in symbols.items():
        path = symbol["pathComponents"]
        if path[0] in SURFACE_TYPES or path[0] in BLOB_SURFACE_TYPES:
            surface[precise] = symbol
            if path[0] == "HostJournal" and len(path) > 1 and (len(path) != 2 or path[1] not in REQUIRED_HOST_CALLS):
                problems.append(f"unreviewed host call {'.'.join(path)}")
            if path[0] == "BlobTransferService" and len(path) > 1 and (len(path) != 2 or path[1] not in REQUIRED_BLOB_CALLS):
                problems.append(f"unreviewed blob call {'.'.join(path)}")
        elif symbol.get("spi"):
            allowed = SURFACE_MEMBERS.get(path[0], set())
            if len(path) != 2 or path[1] not in allowed:
                problems.append(f"unreviewed SPI symbol {'.'.join(path)}")
            surface[precise] = symbol

    present = {tuple(symbol["pathComponents"]) for symbol in surface.values()}
    for name in SURFACE_TYPES | BLOB_SURFACE_TYPES:
        if (name,) not in present:
            problems.append(f"missing surface type {name}")
    for owner, members in SURFACE_MEMBERS.items():
        for member in members:
            if (owner, member) not in present:
                problems.append(f"missing surface member {owner}.{member}")
    for call in REQUIRED_HOST_CALLS:
        if ("HostJournal", call) not in present:
            problems.append(f"missing host call HostJournal.{call}")
    for call in REQUIRED_BLOB_CALLS:
        if ("BlobTransferService", call) not in present:
            problems.append(f"missing blob call BlobTransferService.{call}")

    for precise, symbol in surface.items():
        where = ".".join(symbol["pathComponents"])
        if FORBIDDEN_NAMES.search(where):
            problems.append(f"{where} has a forbidden name")
        for fragment in fragments(symbol):
            reference = fragment.get("preciseIdentifier", "")
            if fragment.get("kind") == "typeIdentifier" and FORBIDDEN_NAMES.search(fragment.get("spelling", "")):
                problems.append(f"{where} references {fragment['spelling']}")
            if reference.startswith(FORBIDDEN_MODULE_PREFIXES):
                problems.append(f"{where} references {fragment.get('spelling')} from another module ({reference})")
            if reference.startswith("s:7GotSync") and reference not in symbols:
                problems.append(f"{where} references {fragment.get('spelling')}, which is not public")

    for relationship in relationships:
        if relationship["source"] in surface and relationship["kind"] in ("conformsTo", "inheritsFrom"):
            target = relationship.get("targetFallback") or relationship["target"]
            if FORBIDDEN_NAMES.search(target) or relationship["target"].startswith(FORBIDDEN_MODULE_PREFIXES):
                where = ".".join(surface[relationship["source"]]["pathComponents"])
                problems.append(f"{where} {relationship['kind']} {target}")

    if problems:
        fail(sorted(set(problems)))
    print(f"SPI surface check passed: {len(surface)} symbols in {len(SURFACE_TYPES | BLOB_SURFACE_TYPES)} types and "
          f"{sum(len(members) for members in SURFACE_MEMBERS.values())} members")


if __name__ == "__main__":
    main()
