# GotSync protocol

This document describes protocol version 2, which `SyncEngine` runs. Each
linked set of devices is an MLS group (RFC 9420) driven through OpenMLS. The
relay forwards pairing frames between two sockets and stores an ordered log of
MLS messages per group; it holds no application keys. See
[COMPATIBILITY.md](COMPATIBILITY.md) for version identifiers and the cutover
from version 1, and [THREAT-MODEL.md](THREAT-MODEL.md) for security limits.

## Groups and identities

Each linked set of devices is one MLS group (RFC 9420, ciphersuite
`MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519`) of up to eight members. The
OpenMLS state, signing key, and epoch secrets are managed by
`Packages/GotSyncMLS` and stored encrypted on the device.
A member's fingerprint is the SHA-256 of its MLS signature public key. The
relay's `/v2/mls` delivery service holds KeyPackages and an ordered,
per-group log of commits and application messages.

Any member can invite another device. Pairing always runs between two
devices: the inviting member and the joining device. After the joiner is
added, every member reads the same group log, so groups of any size up to
eight deliver operations the same way.

### Invitation

An invitation holds a 16-byte random `secret`. The URL form is
`<scheme>://pair?v=2&secret=…&group=…&fingerprint=…`, with canonical
base64url values: the 32-byte group ID and the inviter's 32-byte fingerprint.
The phrase encodes `secret` alone as 17 words: one word per byte from a
fixed 256-word list, then a checksum word for the first byte of
SHA-256(`secret`). A phrase is a lookup key: the joiner learns the group ID and
fingerprint from the inviter's offer. Extending the mnemonic to carry them
would need 81 words.

Each value below is HKDF-SHA256 over `secret` with no salt, a 32-byte output,
and the info string `com.gotdone.sync/<label>`:

| Label | Use |
| --- | --- |
| `mls-pairing-token/v2` | KeyPackage pairing token; the relay stores its SHA-256 |
| `mls-pairing-route/v2` | Relay WebSocket pairing room |
| `mls-pairing-offer/v2` | ChaCha20-Poly1305 key for frames from the inviter |
| `mls-pairing-response/v2` | ChaCha20-Poly1305 key for frames from the joiner |

### Pairing frames

Both devices join the `/v2/pairing` WebSocket room for the route. Each binary frame is
one kind byte followed by the ChaCha20-Poly1305 combined box (nonce,
ciphertext, tag). The associated data is
`com.gotdone.sync/mls-pairing-frame/v2` followed by the kind byte.

| Kind | Direction | Plaintext |
| --- | --- | --- |
| 1 offer | inviter to joiner | group ID ‖ inviter fingerprint |
| 4 commitment | joiner to inviter | 32-byte commitment `C` |
| 5 nonce | inviter to joiner | 32-byte inviter nonce `Ni` |
| 2 response | joiner to inviter | KeyPackage reference ‖ joiner fingerprint ‖ 32-byte joiner nonce `Nj` |
| 3 decision | either | one byte: 1 added, 0 declined or cancelled |

The exchange runs in this order:

1. The inviter sends the offer on each `peerReady`. A joiner holding a URL
   rejects an offer whose group ID or fingerprint differs from the URL.
2. The joiner publishes a KeyPackage under the pairing token, draws a random
   `Nj`, and sends the commitment
   `C = SHA-256("com.gotdone.sync/mls-pairing-commitment/v2" ‖ group ID ‖ inviter fingerprint ‖ KeyPackage reference ‖ joiner fingerprint ‖ Nj)`.
3. The inviter binds the first commitment it receives for the invitation and
   answers with a random `Ni`. It repeats the same `Ni` if the same commitment
   arrives again after a reconnect. A different commitment aborts the attempt.
4. The joiner accepts one `Ni` per attempt, then sends the response. The
   inviter recomputes `C` from the response and aborts on a mismatch.
5. The inviter fetches the KeyPackage, checks that its SHA-256 equals the
   reference, and both devices show the safety code.

The safety code is the first four bytes of SHA-256 over
`com.gotdone.sync/mls-safety-code/v2` ‖ group ID ‖ inviter fingerprint ‖ joiner
fingerprint ‖ `Ni` ‖ `Nj`, read big-endian, modulo 1,000,000, printed as six
digits.

The commitment is the hash-commitment construction used for short
authentication strings (as in ZRTP and Bluetooth numeric comparison). Without
it, a party holding the invitation could learn the real joiner's code and
generate KeyPackages offline until one produced the same six digits. With it,
the joiner fixes its KeyPackage, fingerprint, and `Nj` before `Ni` exists, and
the inviter fixes `Ni` before `Nj` is revealed. Each attempt to match another
device's code therefore succeeds with probability 10⁻⁶ and costs one online
pairing attempt, which the inviter's user sees.

The inviter waits at most 10 minutes for approval. The relay discards an
unused KeyPackage 15 minutes after publication, so an approved KeyPackage can
always be added. When the wait ends, the inviter sends a declined decision and
reports `SyncError.approvalExpired`.

After approval, a founding inviter creates the group. A linked inviter first
catches up and commits pending removals. It then commits an Add with the
joiner fingerprint behind the code as the verified fingerprint. OpenMLS
rejects a KeyPackage whose signature key does not match. The inviter retries a
superseded Add up to three times. The joiner polls the log until a commit
carries a Welcome for its KeyPackage reference and joins only if the Welcome
signer's fingerprint equals the inviter fingerprint.

The inviter records the added fingerprint as provisional. Any application
message from that member clears the record. If none arrives within 15 minutes,
the inviter removes the member. If the joiner declines while the Add is in
flight, a linked inviter removes the new member immediately, and a founding
inviter discards the group. A joiner that cancels or fails erases its MLS
state, so the private key of an added but unused KeyPackage is gone.

### Replication

Application message plaintext is canonical JSON with `version: 2`:

- `operations` carries up to 256 task operations from any origin.
- `hello` carries the sender's version vector and an optional `provider`
  fingerprint.

A receiver applies each operation whose origin sequence is next. It repeats
until nothing more applies, then sends a `hello` without a provider if
operations still wait on a gap. On a `hello`, a member sends its own
operations up to its upload position that the sender lacks. The member named
as `provider` also sends every other missing origin.

After joining, a device sends a `hello` that names its inviter as provider and
then all retained operations. Each device then uploads its own operations in
sequence. The engine applies received operations and persists the replica
before it answers hellos and acknowledges the MLS inbox. A replay after a
crash is idempotent.

`sync-v2.json` in the storage directory records the group ID, each member's
device ID and fingerprint, the highest own sequence uploaded, whether the join
announcement is pending, requested removals, and provisional members. The MLS
state remains the source of truth: on launch, a group with at least two
members is linked even if the file is missing. Before a joiner waits for
admission it writes the group ID and inviter fingerprint to
`sync-v2-join.json`, so a joiner that stops after admission but before
`sync-v2.json` exists still names its inviter as provider when it relaunches.

An application message that fails MLS validation is skipped. A commit that
fails validation stops the cursor, and the engine reports
`SyncError.syncHistoryBlocked` rather than skipping it. The engine polls the
log every two seconds while active. No WebSocket carries task changes.

### Membership changes

Any member can remove another member with a Remove commit. The delivery entry
for that commit carries `removeWriter`, the hash of the removed member's
writer token. `SyncEngine.removeDevice` first saves the fingerprint in
`sync-v2.json`. Each sync cycle commits one saved removal at a time until the
fingerprint has left the roster. A removal superseded by another commit is
retried in the next epoch, and a target that another member already removed
is dropped. Removals therefore survive restarts and concurrent removals.

A leaving device sends an MLS Remove proposal for its own leaf. The proposal
travels as a delivery entry of kind `proposal` at the current epoch, with no
Welcome, KeyPackage reference, or writer fields. The relay revokes the
appending writer at that cursor: it refuses further appends and serves reads
only up to the proposal. After the leaver acknowledges the proposal, the relay
refuses its reads too.

A receiver accepts a proposal only if it is a Remove from a member for that
member's own leaf. It stores the proposal and records the sender's fingerprint
as departing. OpenMLS refuses to send application messages while a proposal
is pending, so a member commits departing members before it sends. The next
commit of any kind includes the stored proposal by reference. If an epoch ends
before that, the member removes the departing fingerprint by value. An Add
for a KeyPackage whose device ID belongs to a departing member is allowed, and
its commit also removes the old leaf. The same install can therefore be
invited again right after it leaves.

`unlinkAndKeepTasks()` and `eraseLocalData()` move the MLS directory and its
state key to a departure slot under `mls-v2-departing/` before anything else
changes. The engine opens a fresh MLS identity at once and publishes the leave
proposal from the slot in the background. It retries with backoff, at launch,
and when the application becomes active. A slot is erased after the relay
accepts the proposal, or when the relay or MLS state shows that the device is
already outside the group. Each MLS identity uses its own directory, so a
superseded session never shares a path with the session that replaced it.

A device that processes a commit removing it erases its MLS state, keeps its
tasks, and reports `SyncError.removedFromGroup`. A group can shrink to one
member, which stays linked and can invite again.

## Pairing room

Clients connect to the generic `/v2/pairing` WebSocket endpoint and register a room in
the first text frame, so the route never appears in a URL, header, or access
log:

```json
{"type":"register","version":2,"route":"base64url-32-bytes"}
```

The relay validates the size and shape, admits at most two sockets per route,
and forwards later binary frames unchanged to the other socket. It never
buffers a frame before the second peer exists and destroys an empty room at
once. Control frames report `peerReady` and `peerLeft` and carry `version: 2`.
The relay closes a socket that connects to any other path or registers with
another version. Capacity and route
failures use these codes:

| Code | Meaning | WebSocket close |
| --- | --- | ---: |
| `routeFull` | A third socket attempted to join an existing route | 1008 |
| `relayBusy` | The global connection or room limit is full | 1013 |
| `waitingExpired` | A route had only one peer for the waiting TTL | 1008 |

A lone peer expires after 15 minutes by default, the same as the invitation
lifetime. The default process limits are 256 WebSocket connections and 128
rooms. Only aggregate counters are exposed; metrics and logs contain no route,
IP address, user agent, device ID, or payload.

## Delivery service

`/v2/mls` accepts JSON `POST` requests with `version: 2` and canonical
base64url binary fields. A device authenticates with a random 32-byte writer
token kept in its MLS state. The relay stores only the token's SHA-256, which is
also part of the device's MLS credential identity.

| Endpoint | Purpose |
| --- | --- |
| `key-package/publish` | Store a KeyPackage under the SHA-256 of a pairing token for 15 minutes; returns its reference |
| `key-package/fetch` | Return a KeyPackage once, to a caller presenting the pairing token |
| `create` | Register a group ID and its founding writer |
| `append` | Append a `commit`, `application`, or `proposal` entry at the current epoch |
| `fetch` | Return up to 32 entries after a cursor |
| `ack` | Record that this writer has durably processed entries up to a cursor |

An append whose epoch differs from the group's current epoch fails with
`epochConflict`; the client fetches the winning commit and retries. A commit
that adds a member carries its Welcome, the KeyPackage reference, and the new
writer's hash; the relay admits that writer only if the reference belongs to a
KeyPackage published by it, and otherwise answers `keyPackageUnavailable`. A
commit can name `removeWriter`, and a proposal revokes its own sender. Naming
a writer the relay no longer holds has no effect. The relay does not parse
MLS: it trusts these fields and treats payloads as opaque.

A revoked writer cannot append. It can read entries up to its removal cursor
until it acknowledges that cursor or 24 hours pass. The relay deletes entries
that every current writer has acknowledged, and any entry 90 days after it
was accepted. A group log holds at most 10,000 entries or 16 MiB; past that,
appends fail with `deliveryCapacity`. A group with no entries expires after 24
hours, and any group expires 90 days after the last request from a member.
`fetch` answers HTTP 410 `historyExpired` when entries the writer has not
acknowledged have expired. `fetch`, `ack`, and `append` also answer it for a
deleted group. The client then stops with `SyncError.syncHistoryExpired`. The
[server README](../server/README.md#retention) lists the full retention
policy.

## Replicated task model

```text
TaskRecord {
  id: UUID
  title: LWWRegister<String>
  completed: LWWRegister<Bool>
  deletion: RemoveWinsTombstone?
}

Stamp {
  lamport: UInt64
  originDeviceID: 128-bit ID
}

Operation {
  originDeviceID
  originSequence
  lamport
  taskID
  mutation
  value
}
```

Title and completion are independent last-writer-wins registers. Stamps compare
Lamport value first and origin device ID second. Deletion permanently removes a
UUID in this protocol. Restoring an item creates a new UUID.

Each replica persists:

- materialized task records and tombstones;
- every operation;
- its next local origin sequence;
- its Lamport clock;
- the highest contiguous sequence seen for each origin.

An install-scoped 128-bit replica device ID is generated on first launch,
before any task or pairing operation, and stored with a `ThisDeviceOnly`
Keychain class. It is not regenerated when the device leaves a group. Origin sequences
begin at one; zero means that no operation from an origin has been applied.
If the install identity or persistent replica cannot be opened, the engine
enters a fatal local error state: it does not open the MLS session, sync,
accept edits, or acknowledge remote operations through an in-memory fallback.

A local edit atomically persists the operation, materialized state, next origin
sequence, Lamport clock, and local vector before it is sent. A remote batch
atomically persists every accepted operation, materialized state, updated
vectors, and `lamport = max(localLamport, receivedLamport)` before the MLS
inbox is acknowledged. The engine achieves this by atomically replacing one
complete replica archive.

Operations are idempotent by `(originDeviceID, originSequence)`. A repeated ID
must have byte-identical canonical content; different content for an existing
ID is a fork, and the whole batch is rejected.

Mutation cases and apply rules:

```text
create(title, completed)
setTitle(title)
setCompleted(completed)
delete
```

1. Validate IDs, bounds, canonical encoding, and that each origin's new
   operations are contiguous from `vector[origin] + 1`.
2. A local operation increments Lamport, assigns the next origin sequence, and
   uses `Stamp(lamport, localDeviceID)`.
3. Receiving an existing operation ID applies no field effect after its bytes
   are confirmed identical.
4. `delete` creates a grow-only tombstone even for an unknown task. A tombstone
   permanently dominates create and field updates for that UUID.
5. `create` initializes or updates both independent registers when its stamp is
   greater than their current stamps. A local recreate of a tombstoned UUID is
   invalid. A late remote create is retained and may update hidden registers,
   but it cannot remove the tombstone.
6. A local field update requires a retained `create` for that UUID and rejects
   a tombstone. A remote field update may arrive before `create`; it creates a
   durable partial materialized record, advances its origin vector, and updates
   only that register when its stamp wins. The partial record stays hidden
   until a `create` operation is retained and both title and completion
   registers exist, and a deletion tombstone still keeps it hidden. A late
   remote update behind a tombstone is retained without resurrection. Equal
   stamps must contain equal values.
7. Register stamps compare Lamport first, then unsigned lexicographic device-ID
   bytes.
8. After every accepted new operation, advance that origin's contiguous vector
   and update the materialized task.

These rules describe only the sample schema. A richer task model's correlated
completion date and status need one compound register; habit completion
history needs set/map semantics; ordering needs rank or sequence semantics; notifications are
derived local state; images need a blob path; recurring occurrences need
deterministic IDs.

## Version 1

Version 1 was a custom protocol: an X25519 pairing handshake, ChaCha20-Poly1305
live frames between two sockets, HKDF-derived per-pair and group mailbox
envelopes, signed membership snapshots, and rekey records under a shared group
root. The red-team review found it unsound (see SECURITY-RED-TEAM.md), and it
has been removed from the client and the relay. The relay serves no `/v1`
path.
