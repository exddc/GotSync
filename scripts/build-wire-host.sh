#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="${GOTSYNC_WIRE_BUILD:-$repo/.build/wire-host}"
if [ ! -d "$work/source/.git" ]; then
    git clone --depth 1 --branch v10.5.4 https://github.com/wireapp/core-crypto.git "$work/source"
fi
if [ "$(git -C "$work/source" rev-parse HEAD)" != 9c807b0f91fd6cfd8489c4d9cca71142ac3fd351 ]; then
    echo 'Unexpected CoreCrypto source revision' >&2
    exit 1
fi
git -C "$work/source" diff --quiet
git -C "$work/source" diff --cached --quiet
cd "$work/source"
cargo +stable build --locked --release --package core-crypto-ffi --features cancellable-transactions
cargo +stable run --locked --release --package core-crypto-ffi --features uniffi/cli,cancellable-transactions --bin uniffi-bindgen -- generate --library target/release/libcore_crypto_ffi.dylib --language swift --config crypto-ffi/uniffi.toml --out-dir "$work/bindings"
mkdir -p "$repo/Packages/WireCoreCrypto/HostSwift" "$repo/Packages/WireCoreCrypto/HostFFI"
cp "$work/bindings/core_crypto_ffi.swift" "$repo/Packages/WireCoreCrypto/HostSwift/"
cp "$work/bindings/core_crypto_ffiFFI.h" "$repo/Packages/WireCoreCrypto/HostFFI/"
echo "GOTSYNC_WIRE_HOST=$work/source/target/release swift test"
