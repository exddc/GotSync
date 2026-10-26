#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/project-env.sh"
cd "$GOTSYNC_REPO_ROOT"
GOTSYNC_MLS_MARKER="Artifacts/.built"
if [ ! -f "$GOTSYNC_MLS_MARKER" ] && ! command -v cargo >/dev/null; then
    exit 0
fi
if [ ! -f "$GOTSYNC_MLS_MARKER" ] || [ -n "$(find mls/src mls/Cargo.toml mls/Cargo.lock mls/uniffi.toml scripts/build-mls.sh rust-toolchain.toml -type f -newer "$GOTSYNC_MLS_MARKER" -print -quit 2>/dev/null)" ]; then
    scripts/build-mls.sh --host-only
fi
