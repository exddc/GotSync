#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/project-env.sh"
cd "$GOTSYNC_REPO_ROOT"
export CARGO_TARGET_DIR="$GOTSYNC_CACHE_DIR/rust-mls"
cargo test --locked --manifest-path mls/Cargo.toml
scripts/uv.sh pytest server/tests/test_mls.py -q
scripts/ensure-mls.sh --build-if-missing
GOTSYNC_MLS_TEST_DIR="$(mktemp -d)"
GOTSYNC_MLS_SERVER_PID=""
cleanup() {
    if [ -n "$GOTSYNC_MLS_SERVER_PID" ]; then
        kill -TERM "$GOTSYNC_MLS_SERVER_PID" 2>/dev/null || true
        wait "$GOTSYNC_MLS_SERVER_PID" 2>/dev/null || true
    fi
    rm -rf "$GOTSYNC_MLS_TEST_DIR"
}
trap cleanup EXIT INT TERM
"$UV_PROJECT_ENVIRONMENT/bin/python" scripts/run-mls-server.py "$GOTSYNC_MLS_TEST_DIR" > "$GOTSYNC_MLS_TEST_DIR/server.log" 2>&1 &
GOTSYNC_MLS_SERVER_PID=$!
for ((attempt=0; attempt<100; attempt++)); do
    if [ -f "$GOTSYNC_MLS_TEST_DIR/endpoint" ]; then break; fi
    if ! kill -0 "$GOTSYNC_MLS_SERVER_PID" 2>/dev/null; then cat "$GOTSYNC_MLS_TEST_DIR/server.log"; exit 1; fi
    sleep 0.1
done
if [ ! -f "$GOTSYNC_MLS_TEST_DIR/endpoint" ]; then cat "$GOTSYNC_MLS_TEST_DIR/server.log"; exit 1; fi
export GOTSYNC_MLS_URL="$(cat "$GOTSYNC_MLS_TEST_DIR/endpoint")"
swift test --scratch-path "$GOTSYNC_SWIFT_SCRATCH_PATH" --filter GotSyncMLSTests "$@"
