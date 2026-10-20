#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/project-env.sh"
cd "$GOTSYNC_REPO_ROOT"
scripts/ensure-mls.sh
exec swift test --scratch-path "$GOTSYNC_SWIFT_SCRATCH_PATH" "$@"
