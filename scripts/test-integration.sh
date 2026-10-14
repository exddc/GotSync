#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/project-env.sh"
cd "$GOTSYNC_REPO_ROOT"
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
"$UV_PROJECT_ENVIRONMENT/bin/python" scripts/run-integration-server.py "$GOTSYNC_TEST_DIR" > "$GOTSYNC_TEST_DIR/server.log" 2>&1 &
GOTSYNC_TEST_SERVER_PID=$!
for ((attempt=0; attempt<100; attempt++)); do
    if [ -f "$GOTSYNC_TEST_DIR/endpoints.env" ]; then break; fi
    if ! kill -0 "$GOTSYNC_TEST_SERVER_PID" 2>/dev/null; then cat "$GOTSYNC_TEST_DIR/server.log"; exit 1; fi
    sleep 0.1
done
if [ ! -f "$GOTSYNC_TEST_DIR/endpoints.env" ]; then cat "$GOTSYNC_TEST_DIR/server.log"; exit 1; fi
source "$GOTSYNC_TEST_DIR/endpoints.env"
export GOTSYNC_RELAY_URL GOTSYNC_MAILBOX_URL GOTSYNC_INTEGRATION=1 GOTSYNC_REQUIRE_INTEGRATION=1
swift test --scratch-path "$GOTSYNC_SWIFT_SCRATCH_PATH" "$@"
