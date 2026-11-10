#!/bin/bash
# Runs the host runtime matrix in Release and writes every raw line to
# <evidence>/:
#   - writer segments: journal admission and settlement, wall time, ticker;
#   - engine segments: decode, drain continuation, checkpoint save, view and
#     state publication with live subscribers, journal segments, ticker;
#   - the earlier transaction and promotion matrix;
#   - process-cold launches of the journal alone and of the engine.
# Mac first, then the iOS simulator. Machine conditions are logged before and
# after each section, so contended runs stay visible.
# Usage: measure-host-runtime.sh <evidence-dir> [samples=200] [launches=20] [simulator-id]
# GOTSYNC_MATRIX_TRANSACTIONS=0 leaves out the off-main transaction matrix,
# which is reported but not gated, so it can run outside a reference slot.
set -euo pipefail
source "$(dirname "$0")/project-env.sh"
cd "$GOTSYNC_REPO_ROOT"
evidence="$1"
samples="${2:-200}"
launches="${3:-20}"
simulator="${4:-}"
mkdir -p "$evidence"

conditions() {
    {
        echo "== $1 $(date -u +%FT%TZ)"
        uptime
        memory_pressure | tail -1
        ps -A -o %cpu,comm | sort -rn | sed -n '1,5p'
    } >> "$evidence/conditions.log" 2>&1
}

mac_test() {
    swift test -c release -Xswiftc -enable-testing --skip-build --scratch-path "$GOTSYNC_SWIFT_SCRATCH_PATH" "$@" 2>&1
}

conditions "mac build"
swift build -c release -Xswiftc -enable-testing --build-tests --scratch-path "$GOTSYNC_SWIFT_SCRATCH_PATH" > "$evidence/mac-build.log" 2>&1

conditions "mac writer segments"
GOTSYNC_MEASURE_WRITER="$samples" mac_test --filter HostWriterSegmentMeasurementTests \
    | grep -E "WRITER_TIMING|error:" > "$evidence/mac-writer.log"
conditions "mac engine segments"
GOTSYNC_MEASURE_ENGINE="$samples" mac_test --filter "HostEngineTests/testEngineSegments" \
    | grep -E "ENGINE_TIMING|error:" > "$evidence/mac-engine.log"
if [ "${GOTSYNC_MATRIX_TRANSACTIONS:-1}" != 0 ]; then
    conditions "mac transaction matrix"
    GOTSYNC_MEASURE_PROMOTION="$samples" mac_test --filter HostPendingPromotionMeasurementTests \
        | grep -E "PROMOTION_|error:" > "$evidence/mac-transactions.log"
fi

conditions "mac cold launches"
fixture="gotsync-cold-launch-$$"
engine="gotsync-engine-cold-launch-$$"
for launch in $(seq 0 "$launches"); do
    GOTSYNC_COLD_LAUNCH_DIR="$fixture" mac_test --filter "HostColdLaunchMeasurementTests/testColdLaunch" \
        | grep -E "COLD_LAUNCH|error:" >> "$evidence/mac-journal-cold.log"
done
for launch in $(seq 0 "$launches"); do
    GOTSYNC_ENGINE_COLD_LAUNCH_DIR="$engine" mac_test --filter "HostColdLaunchMeasurementTests/testEngineColdLaunch" \
        | grep -E "ENGINE_|error:" >> "$evidence/mac-engine-cold.log"
done
rm -rf "${TMPDIR:-/tmp}/$fixture" "${TMPDIR:-/tmp}/$engine"
conditions "mac done"

if [ -n "$simulator" ]; then
    derived="$GOTSYNC_CACHE_DIR/l2a2c-ios-release"
    ios_test() {
        xcodebuild test-without-building -scheme GotSync -destination "id=$simulator" -configuration Release \
            -derivedDataPath "$derived" "$@" 2>&1
    }
    conditions "ios build"
    xcodebuild build-for-testing -scheme GotSync -destination "id=$simulator" -configuration Release \
        -derivedDataPath "$derived" ENABLE_TESTABILITY=YES > "$evidence/ios-build.log" 2>&1
    conditions "ios writer segments"
    TEST_RUNNER_GOTSYNC_MEASURE_WRITER="$samples" ios_test -only-testing:GotSyncTests/HostWriterSegmentMeasurementTests \
        | grep -E "WRITER_TIMING|error:" > "$evidence/ios-writer.log"
    conditions "ios engine segments"
    TEST_RUNNER_GOTSYNC_MEASURE_ENGINE="$samples" ios_test \
        -only-testing:GotSyncTests/HostEngineTests/testEngineSegmentsForSteadyHostTraffic \
        -only-testing:GotSyncTests/HostEngineTests/testEngineSegmentsForLargeWindows \
        | grep -E "ENGINE_TIMING|error:" > "$evidence/ios-engine.log"
    if [ "${GOTSYNC_MATRIX_TRANSACTIONS:-1}" != 0 ]; then
        conditions "ios transaction matrix"
        TEST_RUNNER_GOTSYNC_MEASURE_PROMOTION="$samples" ios_test -only-testing:GotSyncTests/HostPendingPromotionMeasurementTests \
            | grep -E "PROMOTION_|error:" > "$evidence/ios-transactions.log"
    fi
    conditions "ios cold launches"
    fixture="$evidence/ios-engine-fixture"
    for launch in $(seq 0 "$launches"); do
        TEST_RUNNER_GOTSYNC_ENGINE_COLD_LAUNCH_DIR="$fixture" ios_test \
            -only-testing:GotSyncTests/HostColdLaunchMeasurementTests/testEngineColdLaunchWithAFullJournalAndFourArchives \
            | grep -E "ENGINE_|error:" >> "$evidence/ios-engine-cold.log"
    done
    rm -rf "$fixture"
    xcrun simctl shutdown "$simulator" 2>/dev/null || true
    conditions "ios done"
fi
