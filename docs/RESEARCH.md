# Sync research

Initial research completed on 2026-07-27 before implementation began. The
offline-delivery follow-up was researched on 2026-07-28 before the persistent
mailbox was implemented.

## Product constraints

The proof of concept must have:

- no account, login, analytics identity, or user profile;
- a phrase and QR enrollment experience;
- explicit approval on the existing device;
- end-to-end encrypted content;
- a relay that routes live frames and stores only end-to-end-encrypted offline
  envelopes plus aggregate metrics;
- foreground, low-latency propagation between two iOS devices;
- local durability and deterministic convergence after reconnection.

The proof of concept does not promise:

- delivery of an edit that never reached the mailbox before its only source
  lost connectivity;
- continuous background execution on iOS;
- anonymous networking or traffic-analysis resistance;
- production-ready device revocation, group key rotation, or recovery;
- a cryptographically audited protocol.

## Offline-delivery follow-up

The first implementation required both devices online at the same time. That
preserved a very small server privacy boundary but produced the wrong product
experience. Brave and Signal both demonstrate that asynchronous linked-device
delivery needs a durable server-side queue. The useful privacy goal is not
"zero server storage"; it is "the server stores nothing it can decrypt and
collects no account identity."

The live encrypted-frame format cannot be reused for storage because every
frame is bound to one ephemeral handshake transcript, directional counter, and
nonce prefix. The follow-up therefore keeps live WebSockets unchanged and adds
an independently encrypted mailbox envelope for each immutable operation.

Signal's Sesame specification supplies the important delivery model:
messages may wait in server mailboxes, clients may be offline for arbitrary
periods, and duplicate delivery must be tolerated. The implementation adopts
non-destructive fetch, durable local apply before ACK, and idempotent replay.
It does not adopt Signal accounts, push identifiers, or server-readable
routing identity.

RFC 8439 permits ChaCha20-Poly1305 when a nonce is unique for a key. The POC
derives a fresh per-operation key from a keyed 256-bit operation ID, allowing a
fixed nonce for that independently derived key and exact deterministic retries.
This construction is intentionally documented as custom and unaudited.

iOS does not promise execution after force-quit. Foreground launch/polling is
the reliable receive trigger without APNs. `beginBackgroundTask` only provides
a best-effort grace period to finish an upload already initiated as the app
backgrounds; it is not a scheduler or wake mechanism.

Follow-up sources:

- [Signal Sesame asynchronous multi-device sessions](https://signal.org/docs/specifications/sesame/)
- [ChaCha20 and Poly1305 for IETF protocols, RFC 8439](https://www.rfc-editor.org/rfc/rfc8439.html)
- [Apple: extending your app's background execution time](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time)
- [Apple BackgroundTasks framework](https://developer.apple.com/documentation/backgroundtasks)

## Brave Sync v2

Brave is a strong reference for accountless enrollment, but it is not a
stateless real-time relay.

### Useful ideas

- A first device creates a high-entropy random chain secret.
- QR and mnemonic forms make the same capability easy to transfer.
- The chain secret is kept in OS-protected local storage.
- Keys are domain-separated before they are used for authentication or
  content encryption.
- Clients use stable IDs, versions, tombstones, and idempotent updates.

### Important differences

- Brave's first client creates a 32-byte seed and exposes that permanent
  seed in both its BIP39 words and QR payload. The current extra word limits
  when the UI accepts a manual phrase, but it does not rotate or revoke the
  underlying seed.
- All devices obtain the same seed. Possession grants both decryption and
  chain authentication, so there is no continuing primary-device authority.
- Brave Sync v2 uses Chromium Sync records and stores encrypted entities in
  DynamoDB. The public server implements Commit/GetUpdates and tells clients
  to poll every 30 seconds.
- The server sees routing and conflict metadata, including versions, record
  types, timestamps, opaque IDs, and device information.
- A removed device can retain the shared seed. Cryptographic revocation
  requires a new key epoch, which Brave's shared-seed design does not provide.

Primary sources:

- [Brave seed and BIP39 conversion](https://github.com/brave/brave-core/blob/046bf8ea56af4ff4fea015e053cec94d32e27004/components/brave_sync/crypto/crypto.cc#L22-L36)
- [Brave time-limited word implementation](https://github.com/brave/brave-core/blob/046bf8ea56af4ff4fea015e053cec94d32e27004/components/brave_sync/time_limited_words.cc#L114-L188)
- [Brave QR representation](https://github.com/brave/brave-core/blob/046bf8ea56af4ff4fea015e053cec94d32e27004/components/brave_sync/qr_code_data.cc#L43-L54)
- [Brave authentication derivation](https://github.com/brave/brave-core/blob/046bf8ea56af4ff4fea015e053cec94d32e27004/components/sync/service/brave_sync_auth_manager.cc#L35-L120)
- [Brave Sync v2 architecture and metadata boundary](https://github.com/brave/brave-browser/wiki/Brave-Sync-v2)
- [Brave server entity storage](https://github.com/brave/go-sync/blob/d564bc8ccc71b4e60c9e29bbfd12a32624adbbbf/datastore/sync_entity.go#L39-L60)
- [Brave server polling and batch settings](https://github.com/brave/go-sync/blob/d564bc8ccc71b4e60c9e29bbfd12a32624adbbbf/command/command.go#L17-L31)
- [Brave server DynamoDB schema](https://github.com/brave/go-sync/blob/d564bc8ccc71b4e60c9e29bbfd12a32624adbbbf/schema/dynamodb/table.json)
- [Brave server retention FAQ](https://support.brave.app/hc/en-us/articles/360047642371-Sync-FAQ)

One documentation detail should not be copied without version-specific
verification: Brave's wiki describes AES-CTR plus HMAC, while the pinned
Chromium Nigori source inspected for this research uses AES-CBC plus HMAC. A new
system should use a modern AEAD instead of either custom composition.

## Other implementations

### Signal linked devices

Signal's linking flow is the closest enrollment reference. A new device creates
a temporary Curve25519 key and provisioning address, a QR transfers them, and
the primary sends a one-time encrypted provisioning package. Linked devices
share an account identity in Signal's model but use independent prekeys and
per-device sessions.

Adopt:

- ephemeral public-key provisioning;
- explicit approval by the existing device;
- distinct device identities;
- a separate initial-state transfer.

Adopt the mailbox delivery contract, but store only application-level
end-to-end ciphertext and delete it immediately after durable receipt.

Sources:

- [Signal linked-device provisioning](https://signal.org/blog/a-synchronized-start-for-linked-devices/)
- [Signal Sesame multi-device assumptions](https://signal.org/docs/specifications/sesame/)

### Syncthing

Syncthing is the closest transport architecture. Devices own durable state,
reconcile directly, and may use a relay that only forwards encrypted traffic.
Its documentation also states the unavoidable metadata boundary: a relay still
sees IP addresses, connection timing, byte volume, and which device IDs meet.

Adopt:

- device-owned durable history;
- an opaque bounded relay;
- reconnect reconciliation using device-local versions;
- clear disclosure of relay metadata.

Sources:

- [Syncthing relay protocol](https://docs.syncthing.net/specs/relay-v1.html)
- [Syncthing Block Exchange Protocol](https://docs.syncthing.net/specs/bep-v1.html)
- [Syncthing security principles](https://docs.syncthing.net/users/security.html)

### Magic Wormhole

Magic Wormhole demonstrates how a short one-time code and PAKE can safely
bootstrap an encrypted connection through an untrusted mailbox and transit
relay.

Adopt:

- one-time enrollment capabilities;
- explicit key confirmation;
- treating an unexpected extra participant as an error.

This POC uses a generated 128-bit phrase rather than a human-chosen password,
so it can use the full random value as a PSK. If the phrase is shortened to
low entropy, it must be replaced with a reviewed PAKE such as SPAKE2.

Sources:

- [Magic Wormhole overview](https://magic-wormhole.readthedocs.io/en/latest/welcome.html)
- [SPAKE2, RFC 9382](https://www.rfc-editor.org/rfc/rfc9382.html)

### CRDT and sync systems

The demo task model does not need a general collaborative-document CRDT.
Independent last-writer-wins registers, logical clocks, tombstones, stable
operation IDs, and a version vector are sufficient for title and completion
fields.

Adopt:

- wall clocks only for display;
- Lamport order plus device-ID tie breaking for deterministic field merges;
- per-origin sequences for deduplication and missing-range discovery;
- permanent tombstones in the POC;
- a snapshot fallback after log compaction in a future implementation.

Sources:

- [Foundational CRDT publications](https://www.lip6.fr/Marc.Shapiro/pubs.html)
- [Automerge change and sync terminology](https://automerge.org/docs/reference/glossary/)
- [Automerge Swift sync state](https://automerge.org/automerge-swift/documentation/automerge/syncstate/)

## Platform and standards

The implementation uses platform primitives rather than third-party client
cryptography:

- X25519 through CryptoKit `Curve25519.KeyAgreement`
- HKDF-SHA256
- HMAC-SHA256 key confirmation
- ChaCha20-Poly1305 authenticated encryption
- Keychain storage with a `ThisDeviceOnly` accessibility class
- `URLSessionWebSocketTask` with bounded message sizes

Sources:

- [X25519, RFC 7748](https://www.rfc-editor.org/info/rfc7748/)
- [HKDF, RFC 5869](https://www.rfc-editor.org/info/rfc5869/)
- [ChaCha20-Poly1305, RFC 8439](https://www.rfc-editor.org/info/rfc8439/)
- [Apple Curve25519 key agreement](https://developer.apple.com/documentation/cryptokit/curve25519/keyagreement)
- [Apple ChaChaPoly authenticated decryption](https://developer.apple.com/documentation/cryptokit/chachapoly/open(_:using:authenticating:))
- [Apple Keychain key storage](https://developer.apple.com/documentation/security/storing-keys-in-the-keychain)
- [Apple URLSessionWebSocketTask](https://developer.apple.com/documentation/foundation/urlsessionwebsockettask)

WebSockets must use TLS in production even though application payloads are
end-to-end encrypted. TLS reduces exposed metadata and prevents unauthenticated
network infrastructure from altering the outer transport. The local POC uses
plain `ws://127.0.0.1` with an explicit development-only ATS exception.

## Got Done integration findings

The production app in `/Users/timoweiss/Projects/GotDone` is SwiftUI plus
SwiftData and targets iOS 18.6. Its stable Task and Habit UUID strings are good
sync identifiers, but the models currently lack revisions, field clocks, and
tombstones.

The main integration boundary should be a mutation coordinator and durable
SwiftData outbox:

1. A user mutation, its materialized model update, and its outbound operation
   commit in one SwiftData transaction.
2. Incoming operations apply on `MainActor` with echo suppression.
3. Derived local effects such as notifications and statistics are rebuilt
   after remote changes; they are not synced as device state.
4. Markdown images use a separate content-addressed, chunked blob path.

The current app has many direct `ModelContext.save()` call sites, so attempting
to infer changes after saves would be fragile.

Specific risks:

- concurrent updates to arrays and dictionaries need field-appropriate CRDTs,
  not whole-record last-writer-wins;
- recurring task instances currently use random IDs on each device and can be
  duplicated unless IDs become deterministic from series plus occurrence;
- deletions need durable tombstones;
- initial tutorial data needs explicit merge semantics;
- image storage and SwiftData do not share a transaction;
- reminder changes require local notification reconciliation.

No files in the production Got Done repository are changed by this proof of
concept.

## Decision

The implementation deliberately differs from Brave:

- QR and phrase carry a short-lived invitation, never the long-term pair root.
- Pairing requires both devices online and explicit host approval.
- Ephemeral X25519 plus the invitation PSK derives a pair root.
- Each normal connection performs another ephemeral authenticated handshake.
- The relay keeps a volatile two-socket live router plus a directional,
  capability-authorized encrypted mailbox.
- Each device persists its own operation log and reconciles missing operations
  after reconnect; deterministic mailbox envelopes carry the same immutable
  operations while one peer is offline.

Server storage is an availability choice with a real metadata cost. The relay
now learns stable mailbox pseudonyms, ciphertext sizes, upload/fetch/ACK timing,
cursors, and expiry, but not task contents, device IDs, keys, or an account.
Retained envelopes do not have forward secrecy from later pair-root compromise.
