#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/project-env.sh"
cd "$GOTSYNC_REPO_ROOT"
export CARGO_TARGET_DIR="$GOTSYNC_CACHE_DIR/rust-mls"
python3 scripts/package-mls.py --record-inputs
GOTSYNC_MLS_GENERATED="$GOTSYNC_CACHE_DIR/mls-bindings"
GOTSYNC_MLS_ARTIFACTS="$GOTSYNC_REPO_ROOT/Artifacts"
export IPHONEOS_DEPLOYMENT_TARGET=18.0
export MACOSX_DEPLOYMENT_TARGET=14.0
GOTSYNC_MLS_TARGETS=(aarch64-apple-darwin)
GOTSYNC_MLS_SLICES=(aarch64-apple-darwin)
if [ "${1:-}" != "--host-only" ]; then
    GOTSYNC_MLS_TARGETS+=(x86_64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios)
    GOTSYNC_MLS_SLICES=(macos aarch64-apple-ios ios-simulator)
fi
rustup target add "${GOTSYNC_MLS_TARGETS[@]}"
for target in "${GOTSYNC_MLS_TARGETS[@]}"; do
    cargo build --locked --manifest-path mls/Cargo.toml --release --lib --target "$target"
done
rm -rf "$GOTSYNC_MLS_GENERATED"
mkdir -p "$GOTSYNC_MLS_GENERATED/headers" "$GOTSYNC_MLS_ARTIFACTS" Sources/GotSyncMLSBindings
(cd mls && cargo run --locked --features bindgen --bin uniffi-bindgen -- generate \
    --library "$CARGO_TARGET_DIR/aarch64-apple-darwin/release/libgotsync_mls.dylib" \
    --language swift --out-dir "$GOTSYNC_MLS_GENERATED")
cp "$GOTSYNC_MLS_GENERATED/GotSyncMLSBindings.swift" Sources/GotSyncMLSBindings/
cp "$GOTSYNC_MLS_GENERATED/gotsync_mlsFFI.h" "$GOTSYNC_MLS_GENERATED/headers/"
cp "$GOTSYNC_MLS_GENERATED/gotsync_mlsFFI.modulemap" "$GOTSYNC_MLS_GENERATED/headers/module.modulemap"
gotsync_mls_library() {
    echo "$CARGO_TARGET_DIR/$1/release/libgotsync_mls.a"
}
GOTSYNC_MLS_XCARGS=()
for slice in "${GOTSYNC_MLS_SLICES[@]}"; do
    case "$slice" in
        macos) members=(aarch64-apple-darwin x86_64-apple-darwin) ;;
        ios-simulator) members=(aarch64-apple-ios-sim x86_64-apple-ios) ;;
        *) members=() ;;
    esac
    library="$(gotsync_mls_library "$slice")"
    if [ ${#members[@]} -gt 0 ]; then
        library="$CARGO_TARGET_DIR/universal/$slice/libgotsync_mls.a"
        mkdir -p "$(dirname "$library")"
        lipo -create "$(gotsync_mls_library "${members[0]}")" "$(gotsync_mls_library "${members[1]}")" -output "$library"
    fi
    GOTSYNC_MLS_XCARGS+=(-library "$library" -headers "$GOTSYNC_MLS_GENERATED/headers")
done
rm -rf "$GOTSYNC_MLS_ARTIFACTS/gotsync_mlsFFI.xcframework"
xcodebuild -create-xcframework "${GOTSYNC_MLS_XCARGS[@]}" -output "$GOTSYNC_MLS_ARTIFACTS/gotsync_mlsFFI.xcframework"
python3 scripts/package-mls.py --record-build
touch "$GOTSYNC_MLS_ARTIFACTS/.built"
