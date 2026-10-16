# Wire CoreCrypto alternative for TW-531

This review branch replaces the custom client crypto path with Wire CoreCrypto
10.5.4. Its intended reader is an engineer comparing this implementation with
the separate OpenMLS PR. It does not depend on, or cherry-pick, that branch.
`SyncEngine` uses this implementation for pairing, task delivery, offline
catch-up, admission, and removal. The replica and its merge rules remain Swift.

## Dependency and adoption gates

The [official release](https://github.com/wireapp/core-crypto/releases/tag/v10.5.4)
contains the iOS arm64 and arm64 simulator frameworks. `Package.swift` pins the
UniFFI archive by SHA-256. The app imports that framework directly through a
small transaction adapter; it does not vendor generated Swift bindings.

CoreCrypto is **GPL-3.0-only**. Compatibility with a closed-source application
and its intended distribution terms is unresolved. This is an adoption gate,
not permission to distribute the dependency under this repository's MIT license.
See the [upstream license](https://github.com/wireapp/core-crypto/blob/v10.5.4/LICENSE).
No external integration security review has been completed. Opus feedback in
this work is internal review, not an independent audit.

The published archive has no macOS slice. `scripts/build-wire-host.sh` checks
out commit `9c807b0f91fd6cfd8489c4d9cca71142ac3fd351`, builds its locked Rust
workspace, and generates local Swift bindings for host tests. Those outputs
are ignored by Git. This adds Rust, SQLCipher/OpenSSL compilation, Wire's
OpenMLS fork, and a binding-generation step to macOS builds. iOS uses the
published binary instead. Rust source compilation is an operational cost,
not a claim about the final application size.

## Pairing and identities

Each installation uses a random UUID as its task-replica identity. CoreCrypto
constructs a BasicCredential client ID with that UUID, device number 1, and
`gotsync.invalid`. This does not create a Wire account or contact Wire services.
Every accepted roster has at most eight distinct client IDs and signing-key
thumbprints. Direct operation batches must name the replica origin associated
with the authenticated MLS sender's thumbprint and client ID.

Pairing requires two role-specific scans. The inviter's QR pins its SDK signing
thumbprint, client ID, group ID, invitation route and expiry. The response QR
pins the exact joiner KeyPackage, client ID, thumbprint and transport-token
hash. The joiner keeps the random transport token in its encrypted database;
it never puts that token in either QR or the KeyPackage directory.

Only the scanned KeyPackage can be admitted. A Welcome is insufficient to
activate the joiner because the public SDK API does not expose its signer.
The joiner waits for an MLS application confirmation authenticated by the
inviter's pinned signing key, naming this invitation and KeyPackage hash.
Other authenticated traffic can advance provisional MLS state but releases no
local task data. This confirmation binds the inviter to the actual joined MLS
context. Merely finding the inviter in the roster is insufficient.

After confirmation, only the pinned inviter can supply the initial checkpoint
for this invitation. The user reviews a local-list conflict before upload.
Existing members ignore those checkpoint payloads; they receive ordinary
operations through their ordered log. This delegates initial history transfer
to the explicitly verified inviter. It does not claim independent historical
signatures for forwarded operations. There is no recurring checkpoint escape
from the direct-sender origin check.

## Durable state and ambiguous delivery

CoreCrypto's `setData` holds the cursor, bounded inbox, outbox, admission state,
and removal state in the same encrypted SQLite transaction as MLS state.
The database key is a random 32-byte Keychain item with
`WhenUnlockedThisDeviceOnly`; it is not synchronizable. Directories are excluded
from backup, use mode 0700 and iOS complete file protection. Locked-device
background work may stop and retry after unlock. The app does not promise push
or continuous background receive.

Application encryption advances the sending ratchet and journals the exact
ciphertext before HTTP delivery. Replica operations remain on disk until
acknowledged. A stale refusal preserves that plaintext source for encryption
under the current epoch. An unknown HTTP outcome retains the exact pending
bytes and does not prevent fetching incoming entries.

The SDK transport callback captures a Commit bundle locally. It never sends
to the network inside the SDK transaction. The wrapper first copies the encrypted database and WAL while its serialized
SDK connection has no transaction in progress. It omits the shared-memory
index, which SQLite rebuilds. The files and directory entry are synchronized
before the candidate filename can be journaled. CoreCrypto merges
there, and the wrapper journals the resulting state and exact Commit/Welcome
bytes in that database. The canonical database durably records the candidate
filename before any network request.

The relay accepts the exact event once or records a durable refusal. On
acceptance, the wrapper persists the receipt in the candidate and atomically
switches the `current` filename. A lost response or restart retries those exact
bytes. A competing Commit leaves the canonical state intact; only a definite
refusal permits discarding its candidate. Candidates never encrypt application
messages before promotion, avoiding sending-ratchet reuse when discarding one.
Orphan copies are removed at startup, and failed staging removes its copy.
Missing journaled candidates fail closed rather than creating an empty store.

Wire 10.5.4's iOS `exportDatabaseCopy` cannot reopen its exported header format.
Its iOS SQLCipher salt also lives in a Keychain entry indexed by the absolute
path, which can change after an app update. `WireDatabaseSalt` is a small,
version-specific compatibility adapter: it captures the SDK salt into the
application's protected SecretStore, restores it before opening a cloned or
moved database, and deletes obsolete path entries. It relies on Wire's internal
`wire.com` service and `keystore_salt_<sha256(path)>` convention. This is an
additional maintenance obligation when updating the SDK. The salt alone is
not the encryption key. Wire marks its own salt entries AfterFirstUnlock;
the application key and retained salt record use WhenUnlockedThisDeviceOnly.
No SDK source patch is used.

Inbox processing commits MLS state, plaintext and cursor together. The replica
then persists its idempotent merge before acknowledging that inbox prefix.
Single-flight engine cycles prevent foreground/background races. Merge approval
acknowledges only the staged prefix, retaining later arrivals.

## Relay contract and limits

The client uses HTTPS `POST /v3/mls`; explicit local-development configuration
allows loopback HTTP. Redirects are rejected and response size is bounded.
The existing `/v1` service remains for old clients and reachability checks;
this client never falls back to its custom encrypted wire format.

Random per-device bearer capabilities authorize group delivery independently
of MLS keys. The relay stores token hashes. A photographed invitation does not
provide a member's append capability. An authenticated Commit atomically
appends the Commit, publishes the encrypted Welcome, consumes the selected
KeyPackage and registers/revokes transport capabilities. The relay does not
validate MLS cryptography; clients do. Authorized malicious members can still
deny service. A malicious relay can always withhold, fork, or delete delivery.

Epoch and head-cursor comparisons select the first accepted Commit. All writes
use a head comparison so acceptance receipts cannot silently skip preceding
entries. Rejected operations have tombstones. Pruning only removes receipts
whose previous cursor can never match the monotonically increasing log again.
Capacity backpressure has an unknown disposition and keeps the pending bytes.

The log prunes below the minimum acknowledged device cursor, including a
removed device until it acknowledges removal or 24 hours elapse. Offline active devices keep
their necessary history. A removed capability can fetch through its removal
entry, not subsequent traffic. A leave is an authenticated MLS request;
another member commits the removal. It may wait for that member to come online.

The relay bounds live history to 10,000 events and about 16 MiB per group,
20,000 outstanding decisions, 128 groups, and 1,024 pairing records. Pairing
records expire; consumed Welcomes remain available for up to 30 days. A long
offline member can hold back pruning and trigger backpressure. Deployment
admission/rate limiting remain required for a public service;
local unlink retires an empty group and frees its live quota slot, while
retaining a route tombstone. Anonymous creation can exhaust the global group quota.
These are explicit service-operating limits, not unlimited offline storage.

MLS PublicMessage commits expose group IDs, membership and public keys to the
relay. PrivateMessage headers also expose the group ID and epoch. Routes are
not hidden by hashing the group ID. Payload lengths, timing and IP addresses
remain observable. All members share task content; there is no within-group
privacy boundary.

## Validation and remaining gates

The final hosted iOS Simulator run passed all 66 tests against the real relay.
The host suite passed 46 tests with one skipped subprocess-only helper; the
server suite passed 61 tests. These counts include retained replica and app
surface tests.

`WireMLSTests` exercises the real relay with two and three CoreCrypto clients,
including the actual `SyncEngine`, both-list merge, offline reopening,
concurrent commits, QR substitution, lost acceptance responses, removal,
leave requests, tamper rollback, origin checks, and expiry/cancellation.
Relay tests cover atomic delivery, one-use/expired KeyPackages, refusal
tombstones, revoked capabilities and pruning below the slowest cursor.

A lost-response test reopens persisted databases after actual relay acceptance.
A separate subprocess test uses SIGKILL immediately after relay acceptance,
then recovers the exact durable candidate. The forged-Welcome test includes
the inviter's real public leaf but requires its actual MLS signature. A raw
SDK test attempts subsequent decryption using a saved pre-removal database,
first verifying that its original two-member conversation is still present.
Database relocation with a pending accepted commit and background resume are
also regression tests. The replica retains its existing limits of 10,000
operations, 1,000 tasks and eight historical writer identities. Exceeding a
replica limit now produces a visible repair failure instead of an offline
status. Historical compaction is not implemented. A malformed authenticated
application entry also fails closed and requires repair; it is not silently
skipped. Authorized insiders and incompatible versions can therefore deny
service. Device power-loss tests remain a release gate, along with physical camera
scans, locked-phone execution and external integration review. The
physical iPhone was unavailable while locked; no physical-device success is
claimed. No audited-security or broad privacy claim is made.

Local deletion unlinks databases and deletes the application Keychain key.
It cannot prove physical erasure from flash, old filesystem snapshots, vendor
Keychain internals, or another member's saved plaintext. Restoring an old MLS
database is unsupported because it can reuse sending ratchet generations.

## Measured build sizes

On this host, unsigned arm64 iOS Release builds with the same Xcode and endpoint
settings measured 5,846,733 bytes for upstream main's complete app bundle and
34,279,659 bytes for this branch: a 28,432,926-byte increase (27.12 MiB). The
Wire framework inside the latter measured 29,714,696 bytes; the app executable
itself measured 4,562,048 bytes versus 5,844,928 bytes before the change.
These are local uncompressed bundle-file totals, not an App Store download,
installed allocation, or a universal/thinned distribution estimate. Dependency
extraction, dSYMs and Rust build caches are excluded. Re-measure after release
configuration, signing, stripping, thinning, or dependency changes.

## Review ownership counts

At this review snapshot, the change adds about 2,256 lines of authored production
logic, 1,128 test lines and 59 build/metadata lines. Documentation is separate.
No generated bindings or dependency lockfile lines are added to Git. The SDK
binary is downloaded by pinned checksum; the host build uses the upstream
revision's Cargo.lock. These counts measure added lines, not the size of the
resulting codebase. Large deletions remove the old custom protocol and tests.

Compare those categories separately with the OpenMLS option. Its lockfile and
generated/build packaging should not be counted as authored production logic.
Neither Rust nor a dependency's extraction size indicates an application-size
penalty. The measured Release app delta above is the relevant local binary
comparison. The separate option's ongoing packaging changes are not frozen by
this snapshot.
