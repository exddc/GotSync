#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/project-env.sh"
cd "$GOTSYNC_REPO_ROOT"
scripts/ensure-mls.sh --ios
GOTSYNC_DERIVED_DATA="$GOTSYNC_CACHE_DIR/example-transport"
GOTSYNC_BUILD_LOG="$GOTSYNC_CACHE_DIR/example-transport.log"
build_example() {
    xcodebuild -project Examples/AccountlessSync/AccountlessSync.xcodeproj -scheme AccountlessSync \
        -destination 'generic/platform=iOS Simulator' -derivedDataPath "$GOTSYNC_DERIVED_DATA" \
        CODE_SIGNING_ALLOWED=NO ARCHS=arm64 -quiet "$@" build
}
expect_release_rejected() {
    local expected="$1"
    shift
    if build_example -configuration Release "$@" > "$GOTSYNC_BUILD_LOG" 2>&1; then
        echo "Release build accepted $*"
        exit 1
    fi
    if ! grep -q "$expected" "$GOTSYNC_BUILD_LOG"; then
        cat "$GOTSYNC_BUILD_LOG"
        echo "Release build failed for another reason; log: $GOTSYNC_BUILD_LOG"
        exit 1
    fi
}
build_example -configuration Debug
debug_ats="$(/usr/libexec/PlistBuddy -c "Print :NSAppTransportSecurity:NSAllowsLocalNetworking" \
    "$GOTSYNC_DERIVED_DATA/Build/Products/Debug-iphonesimulator/AccountlessSync.app/Info.plist" 2>/dev/null || true)"
[ "$debug_ats" = true ] || { echo "Debug build lost its local networking exception"; exit 1; }
build_example -configuration Release
expect_release_rejected "must not contain NSAppTransportSecurity" \
    INFOPLIST_PREPROCESSOR_DEFINITIONS=GOTSYNC_ALLOW_LOCAL_NETWORKING
expect_release_rejected "must not compile DEBUG-only code" \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG
echo "Release transport check passed"
