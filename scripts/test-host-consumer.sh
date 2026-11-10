#!/bin/bash
# Builds and tests the HostJournalPreview consumer as an external package
# against GotSync at the URL and revision its Package.swift pins, resolved
# from scratch outside this checkout, then checks the SPI surface.
set -euo pipefail
source "$(dirname "$0")/project-env.sh"
cd "$GOTSYNC_REPO_ROOT"
CONSUMER=Consumers/HostJournalPreviewConsumer

forbidden="$(grep -rnE '@testable|import (GotSyncMLS|GotSyncMLSBindings|SQLite3|gotsync_mlsFFI)|[Gg]ot[Dd]one' \
    "$CONSUMER/Sources" "$CONSUMER/Tests" "$CONSUMER/Package.swift" || true)"
if [ -n "$forbidden" ]; then
    echo "The consumer must use only the public and HostJournalPreview API:"
    echo "$forbidden"
    exit 1
fi
if grep -rnE '^[[:space:]]*import[[:space:]]+GotSync([[:space:]]|$)' "$CONSUMER/Sources" "$CONSUMER/Tests"; then
    echo "The consumer imports GotSync without the HostJournalPreview SPI"
    exit 1
fi

pinned="$(grep -oE '\.package\(url: "[^"]+", revision: "[0-9a-f]{40}"\)' "$CONSUMER/Package.swift" || true)"
if [ -z "$pinned" ] || grep -q 'path:' "$CONSUMER/Package.swift"; then
    echo "The consumer must pin GotSync by URL and full revision"
    exit 1
fi
revision="$(printf '%s' "$pinned" | grep -oE '[0-9a-f]{40}')"

python3 -B -m unittest discover -s scripts/tests -p 'test_host_spi_surface.py'
uv sync --project server --locked --no-editable
GOTSYNC_TEST_DIR="$(mktemp -d)"
GOTSYNC_TEST_SERVER_PID=""
cleanup() {
    if [ -n "$GOTSYNC_TEST_SERVER_PID" ]; then
        kill -TERM "$GOTSYNC_TEST_SERVER_PID" 2>/dev/null || true
        wait "$GOTSYNC_TEST_SERVER_PID" 2>/dev/null || true
    fi
    rm -rf "$GOTSYNC_TEST_DIR"
}
trap cleanup EXIT INT TERM

GOTSYNC_COPY="$GOTSYNC_TEST_DIR/consumer"
mkdir -p "$GOTSYNC_COPY"
rsync -a --exclude .build --exclude .swiftpm "$CONSUMER/" "$GOTSYNC_COPY/"

mkdir -p "$GOTSYNC_TEST_DIR/server"
"$UV_PROJECT_ENVIRONMENT/bin/python" scripts/run-integration-server.py "$GOTSYNC_TEST_DIR/server" > "$GOTSYNC_TEST_DIR/server.log" 2>&1 &
GOTSYNC_TEST_SERVER_PID=$!
for ((attempt=0; attempt<100; attempt++)); do
    if [ -f "$GOTSYNC_TEST_DIR/server/endpoints.env" ]; then break; fi
    if ! kill -0 "$GOTSYNC_TEST_SERVER_PID" 2>/dev/null; then cat "$GOTSYNC_TEST_DIR/server.log"; exit 1; fi
    sleep 0.1
done
if [ ! -f "$GOTSYNC_TEST_DIR/server/endpoints.env" ]; then cat "$GOTSYNC_TEST_DIR/server.log"; exit 1; fi
source "$GOTSYNC_TEST_DIR/server/endpoints.env"
export GOTSYNC_RELAY_URL GOTSYNC_MAILBOX_URL GOTSYNC_INTEGRATION=1 GOTSYNC_REQUIRE_INTEGRATION=1

(
    cd "$GOTSYNC_COPY"
    swift test --scratch-path "$GOTSYNC_TEST_DIR/build"
    python3 - "$revision" <<'PY'
import json
import sys

with open("Package.resolved") as file:
    pins = [pin for pin in json.load(file).get("pins", []) if pin.get("identity") == "gotsync"]
if len(pins) != 1 or pins[0].get("location") != "https://github.com/exddc/GotSync.git" or pins[0].get("state", {}).get("revision") != sys.argv[1]:
    sys.exit(f"GotSync did not resolve to {sys.argv[1]}")
PY
    xcodebuild -scheme HostJournalPreviewConsumer -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath "$GOTSYNC_TEST_DIR/ios" -clonedSourcePackagesDirPath "$GOTSYNC_TEST_DIR/ios-packages" \
        CODE_SIGNING_ALLOWED=NO -quiet build
)

"$UV_PROJECT_ENVIRONMENT/bin/python" scripts/check-host-spi-surface.py
echo "Host consumer check passed"
