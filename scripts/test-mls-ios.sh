#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/project-env.sh"
cd "$GOTSYNC_REPO_ROOT/Packages/GotSyncMLS"
xcodebuild -scheme GotSyncMLS -destination 'generic/platform=iOS' \
    -derivedDataPath "$GOTSYNC_CACHE_DIR/mls-ios" CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
GOTSYNC_MLS_TEST_SIM=""
cleanup() {
    if [ -n "$GOTSYNC_MLS_TEST_SIM" ]; then
        xcrun simctl shutdown "$GOTSYNC_MLS_TEST_SIM" 2>/dev/null || true
        xcrun simctl delete "$GOTSYNC_MLS_TEST_SIM"
        GOTSYNC_MLS_TEST_SIM=""
    fi
}
trap cleanup EXIT INT TERM
GOTSYNC_MLS_TEST_SIM="$(xcrun simctl create "GotSync MLS tests" "${GOTSYNC_MLS_SIMULATOR_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-16}")"
xcodebuild -scheme GotSyncMLS \
    -destination "platform=iOS Simulator,id=$GOTSYNC_MLS_TEST_SIM" \
    -derivedDataPath "$GOTSYNC_CACHE_DIR/mls-ios-tests" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES test
