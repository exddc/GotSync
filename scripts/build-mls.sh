#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/project-env.sh"
cd "$GOTSYNC_REPO_ROOT"
export CARGO_TARGET_DIR="$GOTSYNC_CACHE_DIR/rust-mls"
python3 scripts/package-mls.py --record-inputs
GOTSYNC_MLS_PACKAGE="$GOTSYNC_REPO_ROOT/Packages/GotSyncMLS"
GOTSYNC_MLS_GENERATED="$GOTSYNC_CACHE_DIR/mls-bindings"
GOTSYNC_MLS_ARTIFACTS="$GOTSYNC_MLS_PACKAGE/Artifacts"
export IPHONEOS_DEPLOYMENT_TARGET=18.0
export MACOSX_DEPLOYMENT_TARGET=14.0
GOTSYNC_MLS_TARGETS=(aarch64-apple-darwin)
if [ "${1:-}" != "--host-only" ]; then
    GOTSYNC_MLS_TARGETS+=(aarch64-apple-ios aarch64-apple-ios-sim)
fi
rustup target add "${GOTSYNC_MLS_TARGETS[@]}"
for target in "${GOTSYNC_MLS_TARGETS[@]}"; do
    cargo build --locked --manifest-path mls/Cargo.toml --release --lib --target "$target"
done
mkdir -p "$GOTSYNC_MLS_GENERATED" "$GOTSYNC_MLS_PACKAGE/Sources/GotSyncMLSBindings" "$GOTSYNC_MLS_ARTIFACTS"
(cd mls && cargo run --locked --features bindgen --bin uniffi-bindgen -- generate \
    --library "$CARGO_TARGET_DIR/aarch64-apple-darwin/release/libgotsync_mls.dylib" \
    --language swift --out-dir "$GOTSYNC_MLS_GENERATED")
cp "$GOTSYNC_MLS_GENERATED/GotSyncMLSBindings.swift" "$GOTSYNC_MLS_PACKAGE/Sources/GotSyncMLSBindings/"
mkdir -p "$GOTSYNC_MLS_GENERATED/headers"
cp "$GOTSYNC_MLS_GENERATED/gotsync_mlsFFI.h" "$GOTSYNC_MLS_GENERATED/headers/"
cp "$GOTSYNC_MLS_GENERATED/gotsync_mlsFFI.modulemap" "$GOTSYNC_MLS_GENERATED/headers/module.modulemap"
GOTSYNC_MLS_XCARGS=()
for target in "${GOTSYNC_MLS_TARGETS[@]}"; do
    GOTSYNC_MLS_XCARGS+=(-library "$CARGO_TARGET_DIR/$target/release/libgotsync_mls.a" -headers "$GOTSYNC_MLS_GENERATED/headers")
done
rm -rf "$GOTSYNC_MLS_ARTIFACTS/GotSyncMLSFFI.xcframework"
xcodebuild -create-xcframework "${GOTSYNC_MLS_XCARGS[@]}" -output "$GOTSYNC_MLS_ARTIFACTS/GotSyncMLSFFI.xcframework"
python3 scripts/package-mls.py --record-build
touch "$GOTSYNC_MLS_ARTIFACTS/.built"
