# MLS migration spike

For engineers deciding whether to replace the sync engine's custom protocol.
This is an experimental foundation for TW-531, not the completed migration.
`SyncEngine` still uses the v1 custom protocol. Its security findings remain
open. The experimental package and loopback delivery service never run inside
the v1 engine or the production relay.

## Recommendation

Continue the OpenMLS implementation, provisionally. OpenMLS 0.9.1 with the
RustCrypto provider builds for arm64 macOS, iOS device, and iOS Simulator.
UniFFI 0.32.2 generates synchronous Swift bindings that compile in Swift 6 mode.
The wrapper supports a group, verified admission, removal, pending commits,
and durable application delivery without defining cryptographic primitives.

The alternative comparison uses mls-rs 0.56.0 with its RustCrypto provider.
The checked-in comparison pairs two clients and delivers an application
message on the host; its library also cross-compiles for arm64 iOS. This is a
smaller evaluation than the OpenMLS implementation, not a comparative audit
or a complete CryptoKit-provider benchmark.

The [mls-rs upstream UniFFI wrapper](https://github.com/awslabs/mls-rs/blob/main/mls-rs-uniffi/Cargo.toml)
currently depends on its OpenSSL provider. Using the
[CryptoKit provider](https://github.com/awslabs/mls-rs/blob/main/mls-rs-crypto-cryptokit/README.md)
requires its Swift-to-C bridge as well as Rust-to-Swift bindings. That extra
integration is a reason to continue the primary candidate, not evidence that
mls-rs performs worse. Its [security notice](https://github.com/awslabs/mls-rs/blob/main/mls-rs/README.md#security-notice)
says conformance validation does not constitute a full third-party audit.
Revisit the choice if OpenMLS fails the device, size, or storage gates.

[OpenMLS documents](https://github.com/openmls/openmls#supported-platforms)
that its iOS target is built but not tested upstream. The application must own
that testing. The [UniFFI Swift guide](https://mozilla.github.io/uniffi-rs/latest/swift/overview.html)
describes concurrency limitations. This spike uses synchronous FFI calls inside
a Swift actor and exposes only Swift `Sendable` values across that actor.

## Build and run

The existing root Swift package needs no Rust build. The experimental package
at `Packages/GotSyncMLS` requires generated local artifacts before SwiftPM can
resolve it. Generated bindings and XCFrameworks are excluded from Git.

```sh
scripts/build-mls.sh                 # arm64 macOS, iOS device, iOS Simulator
scripts/test-mls.sh                  # Rust, Python, Swift + real delivery service
scripts/measure-mls.sh               # macOS executable size and initialization
cargo test --locked --manifest-path mls/comparison/Cargo.toml
cargo build --locked --release --target aarch64-apple-ios \
  --manifest-path mls/comparison/Cargo.toml
```

Requires Rust 1.91 or newer, Swift 6, Xcode, and uv. Measurements below used
Rust 1.99.0 and Apple Swift 6.4. The lockfiles pin the Rust dependency graphs.
The build script sets iOS 18 and macOS 14 deployment targets. Intel slices are
not included in this arm64 spike. `scripts/build-mls.sh --host-only` shortens
local iteration; run the full script before an iOS build.

For an unlocked development device, use Xcode's `GotSyncMLS-Package` test
scheme from the experimental package. For simulator tests:

```sh
scripts/build-mls.sh
scripts/test-mls-ios.sh
```

The simulator command requires an installed iOS runtime. It creates a
disposable iPhone 16 simulator, runs Xcode tests, then shuts down and deletes
that simulator. `GOTSYNC_MLS_SIMULATOR_TYPE` can select another installed device
type. The real-relay test runs on macOS through
`scripts/test-mls.sh`; without `GOTSYNC_MLS_URL` it explicitly skips. CI runs
both the iOS build/test job and the host relay test. Both server scripts stop
their servers and remove temporary databases on exit.

## Measurements and device results

Measured on 15 October 2026:

- OpenMLS: all three arm64 Rust slices built and packaged into one XCFramework.
- mls-rs: host pair-and-sync test passed; arm64 iOS release library built with
  RustCrypto. Its CryptoKit bridge and UniFFI integration were not built here.
- Host size: baseline executable 52,400 bytes; MLS executable 3,437,560 bytes;
  delta 3,385,160 bytes (3.23 MiB). Re-run
  `scripts/measure-mls.sh` for the current result. This compares release macOS
  executables, not thinned iOS apps. Identity plus group creation took 8.66 ms
  in one host run; this is not a latency distribution or device benchmark.
- Physical device: Xcode detected a paired iPhone16,1, but could not enable
  development services because it was locked. The user chose to leave device
  testing pending. No physical-device pass or protection-class result is claimed.
- Swift wrapper and generated bindings: compiled successfully for iOS 18 using
  the device XCFramework slice. The arm64 iOS Simulator test bundle also
  compiled; simulator execution is configured in CI and was not run locally.
  Host tests: 5 Rust protocol tests, 7 Python MLS relay tests, and 11 Swift tests,
  including three clients against the real experimental relay. The full Python
  suite passed all 58 tests. All 114 existing Swift tests passed, including the
  original real-relay integration test.

## State and delivery contract

`MLSClient` owns one identity and at most one group. Each call reads the last
committed snapshot inside a SQLite `BEGIN IMMEDIATE` transaction. Rust builds
an ephemeral OpenMLS provider from that snapshot and returns a new snapshot.
Swift persists the new snapshot, outbox, inbox, epoch, and cursor in one
transaction before exposing the result. No live Rust client can get ahead of
durable storage. A failed transaction leaves the previous snapshot usable.

Creating a message advances the sender ratchet and journals the exact
ciphertext plus its plaintext for epoch-conflict recovery. The spike allows
one outbound operation at a time. Retry the journaled bytes after a timeout.
Never generate another operation to resolve an unknown delivery result.

Creating a commit leaves it pending. Post the commit and optional Welcome
atomically. Consume the ordered log, including earlier application entries,
until the exact commit comes back; only then merge it. A winning competing
commit discards the local pending commit in the same state transaction and
records it in `rejectedCommit()` for caller retry. A pending application is
re-encrypted from its journaled plaintext after an epoch change. A public
unconditional discard API is intentionally absent. If an Add receives the
terminal `keyPackageUnavailable` response, call
`rejectAddForUnavailableKeyPackage` with that commit and rejected epoch. The
relay durably records this refusal before responding and will never accept
those commit bytes later, even if the KeyPackage is republished. Do not call
this method after an epoch conflict, timeout, or ambiguous network failure.

Call `process` only in the sequence returned by `fetch`, starting at `cursor()`.
An append response is a delivery receipt, not permission to skip earlier log
entries. Applying an incoming message stores plaintext in the protected inbox
with the consumed message secrets and cursor. After applying that inbox item
durably to the application, call `acknowledgeInbox`. Redelivery after a crash
is harmless; decryption is not repeated. The future engine must make replica
updates idempotent because a crash can occur before acknowledging the inbox.

Incoming sender identity is the SHA-256 fingerprint of the authenticated MLS
leaf signing key, not the self-selected BasicCredential device identifier.
Invalid application entries are recorded and skipped without changing MLS
state. An invalid commit leaves the cursor and MLS state unchanged; it signals
a fork or corrupted delivery log and requires repair/re-pairing. An epoch
ahead of local state or authenticated contents that contradict the envelope
also fail without advancing state. The relay can
always deny service. The client does not silently skip an epoch transition.

## Pairing and membership

The joining device publishes a single-use KeyPackage. The existing device
must obtain its signing-key fingerprint from that joining device's QR, not
from the relay directory. `prepareAdd` validates the KeyPackage, fingerprint,
and package reference before making an Add commit. The joining device must
separately pin the inviter's signing-key fingerprint and expected group ID.
`join` checks the authenticated Welcome signer before accepting the group.
A member merely being present in the tree does not authenticate the inviter.

This is a two-direction verification API, not a finished camera or QR user
flow. The future UI must carry the version, identity fingerprint, group ID,
and directory reference with clear role-specific scanning steps. No phrase
fallback or custom handshake is implemented.

Every member may admit a QR-verified device and remove another member, as in
the existing no-administrator policy. MLS authenticates existing members; it
does not make a malicious co-member trustworthy. Basic credentials provide
no external identity authority. `prepareAdd` rejects duplicate signing keys
and credential IDs. Removing oneself is rejected; a leave flow needs
another member to commit the removal.

The chosen suite is RFC 9420's
`MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519`. Handshake and application
messages use the ciphertext wire format. KeyPackages are public. Welcome is
an MLS-encrypted message. Ratchet trees travel inside the encrypted Welcome.
The group retains zero past epochs because the delivery log orders application
messages against commits and rejects appends at stale epochs. OpenMLS consumes
joining KeyPackage private material and used message keys. The wrapper wipes
its persisted group snapshot after authenticated removal.

## Experimental relay limits

`MLSDeliveryServer` binds only to loopback, uses separate tables/database, and
is not registered in the production server. It stores public KeyPackages,
opaque Commit/Welcome/application bytes, and routing metadata. It receives no
MLS signing, HPKE, or epoch encryption keys. Clients authenticate MLS contents;
the relay does not parse or certify ciphertext.

One SQLite transaction conditionally accepts a commit at the current epoch,
appends Commit and Welcome, consumes the KeyPackage, and advances the epoch.
Identical retransmission returns the original cursor, even after the epoch
changes. Another commit at that epoch gets 409. Fetch is nondestructive, so
one reader cannot erase another reader's offline history.

This loopback spike has no append authorization, route rotation, retention,
or public-service abuse controls. Group IDs are routes. A removed member
cannot decrypt the new epoch but can still deny service with invalid log
entries. A stale removed-member commit gets 409; that is ordering enforcement,
not revocation of network access. Production requires an admission/routing
policy that works for offline members without sending MLS encryption keys
to the server. The service caps history at 10,000 entries/64 MiB and the
KeyPackage directory at 128 entries with 15-minute expiry. The terminal
rejection journal also caps at 10,000 entries. Fetch returns one
entry per request. These are test limits, not a production retention policy.

## Remaining acceptance gates

TW-531 stays open. Do not mark TW-532 unblocked or advertise privacy/audit
claims based on this spike. Completion requires:

1. Physical-device pair/sync/removal, locked-file/background tests, and a
   thinned iOS application size delta with an agreed size budget.
2. Final library selection after the device spike, integration of the new
   pairing and mailbox paths into `SyncEngine`, and re-pairing migration with
   v1 wire format and all custom crypto removed.
3. Production delivery authorization, retention, conflict retry UX, durable
   application outbox/replica integration, and a fork/re-pair path.
4. Review of protected storage, backup/restore/rollback behavior, signing-key
   storage, and residual secret copies. SQLite secure-delete and iOS complete
   file protection do not prove erasure of historical APFS blocks or Swift/Rust
   memory copies. Complete protection deliberately prevents locked background use.
5. Independent integration review, linked report, fixed high/critical findings,
   and re-testing of every crypto finding against the engine after cutover.
