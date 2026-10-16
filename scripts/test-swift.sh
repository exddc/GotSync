#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/project-env.sh"
cd "$GOTSYNC_REPO_ROOT"
if [ -z "${GOTSYNC_WIRE_HOST:-}" ]; then
    "$GOTSYNC_REPO_ROOT/scripts/build-wire-host.sh"
    export GOTSYNC_WIRE_HOST="${GOTSYNC_WIRE_BUILD:-$GOTSYNC_REPO_ROOT/.build/wire-host}/source/target/release"
fi
exec swift test --scratch-path "$GOTSYNC_SWIFT_SCRATCH_PATH" "$@"
