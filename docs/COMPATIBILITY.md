# Compatibility

This is a deliberate development wire break with no production migration.
Switching between upstream custom crypto, the OpenMLS alternative, and this
Wire CoreCrypto branch requires re-pairing. Existing task replica archives
remain format 1. Keep tasks before resetting a link.

The active client uses version 3 HTTPS delivery at `/v3/mls` and QR URLs with
an `mls` host and a versioned fragment. It does not negotiate a fallback.
The relay still serves `/v1` for legacy clients; that does not make their
encrypted messages compatible with this client.

The root package targets iOS 18 and macOS 14. Published Wire binaries cover
iOS arm64 and arm64 simulator only. macOS tests require the pinned source
build described in [WIRE-CORECRYPTO.md](WIRE-CORECRYPTO.md). Intel Apple hosts
and simulator slices are not provided by the published release.

The SDK is GPL-3.0-only. Closed-source/App Store adoption is unresolved. The
repository's MIT license does not relicense that dependency.
