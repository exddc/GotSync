#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/project-env.sh"
cd "$GOTSYNC_REPO_ROOT"
swift build --package-path Packages/GotSyncMLS --scratch-path "$GOTSYNC_CACHE_DIR/swift-mls-size" -c release
GOTSYNC_MLS_BIN="$(swift build --package-path Packages/GotSyncMLS --scratch-path "$GOTSYNC_CACHE_DIR/swift-mls-size" -c release --show-bin-path)"
python3 - "$GOTSYNC_MLS_BIN" <<'PY'
import pathlib
import sys
root = pathlib.Path(sys.argv[1])
baseline = (root / "BaselineSmoke").stat().st_size
mls = (root / "MLSSmoke").stat().st_size
print(f"macOS arm64 baseline executable: {baseline} bytes")
print(f"macOS arm64 MLS executable: {mls} bytes")
print(f"macOS executable delta: {mls - baseline} bytes ({(mls-baseline)/1024/1024:.2f} MiB)")
print("This is a host executable comparison, not a thinned iOS application size measurement.")
PY
"$GOTSYNC_MLS_BIN/MLSSmoke"
