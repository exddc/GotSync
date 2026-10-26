#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/project-env.sh"
cd "$GOTSYNC_REPO_ROOT"
GOTSYNC_MLS_MARKER="Artifacts/.built"
GOTSYNC_MLS_FRAMEWORK="Artifacts/gotsync_mlsFFI.xcframework"
has_ios_slices() {
    ls "$GOTSYNC_MLS_FRAMEWORK" 2>/dev/null | grep -q '^ios-'
}
if [ ! -f "$GOTSYNC_MLS_MARKER" ]; then
    if [ "${1:-}" = "--build-if-missing" ]; then
        scripts/build-mls.sh --host-only
    fi
    exit 0
fi
if [ -n "$(find mls/src mls/Cargo.toml mls/Cargo.lock mls/uniffi.toml scripts/build-mls.sh rust-toolchain.toml -type f -newer "$GOTSYNC_MLS_MARKER" -print -quit 2>/dev/null)" ]; then
    if has_ios_slices; then
        scripts/build-mls.sh
    else
        scripts/build-mls.sh --host-only
    fi
fi
if [ "${1:-}" = "--ios" ] && ! has_ios_slices; then
    echo "Artifacts/ holds a macOS-only build. Run scripts/build-mls.sh, or delete Artifacts/ to use the pinned binary." >&2
    exit 1
fi
