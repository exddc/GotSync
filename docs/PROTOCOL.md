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
the `GotSyncMLS` module and stored encrypted on the device.
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
| 2 response | joiner to inviter | KeyPackage reference ‖ joiner fingerprint ‖ 32-byte joiner nonce `Nj` ‖ origin count `n` (one byte, at most 128) ‖ `n` 16-byte origin IDs |
| 3 decision | either | one byte: 1 added, 0 declined or cancelled, 2 refused because the task history is full (inviter only) |

The response lists every origin in the joiner's replica in strictly ascending
byte order. A receiver rejects a response with more than 128 origins, a body
length other than `97 + 16n` bytes, or origins that are unsorted or repeated.
A frame is at most 2,174 bytes.

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
   inviter recomputes `C` from the response and aborts on a mismatch. The
   origin list is not part of `C` or of the safety code; the frame's
   authenticated encryption under the invitation key protects it.
5. The inviter checks the merged task history (see
   [replica capacity](#replica-capacity)). If it has no room, the inviter
   sends decision 2 and stops before it shows a safety code, so nobody can
   approve the attempt.
6. The inviter fetches the KeyPackage, checks that its SHA-256 equals the
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
- `reservation` carries a joiner `member` fingerprint, its sorted origin list
  (at most 128), and the sender's MLS `epoch`.
- `release` carries `member` and the log cursor `reservation` of the sender's
  own claim that it withdraws.
- `reservations` carries a new member's fingerprint as `member`, at most 64
  claims, and `overflowed` when the sender stopped storing claims. Each claim
  has its member, owner, origins, epoch, log cursor, and `released` and
  `admitted` flags.

[Replica capacity](#replica-capacity) describes how the last three are used.

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
announcement is pending, requested removals, provisional members, the
reservations it knows, and whether this member still waits for its
reservations snapshot. The MLS
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
| `rateLimited` | The source already holds its concurrent-socket limit | 1013 |

Per-source admission and rate limits run before registration. A handshake over
the connection-rate limit receives HTTP 429 with `Retry-After`; a handshake that
fails deployment admission receives HTTP 403. MLS delivery requests receive the
same statuses with JSON bodies `{"error":"rateLimited"}` or
`{"error":"admissionDenied"}`. Rejected requests change no room or delivery
state, so a client may retry them unchanged after `Retry-After`.

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

### Replica capacity

A replica holds at most 1,000 task records and tombstones, 10,000 operations,
and 128 origins. An origin is a device whose operations the replica retains.
Removing or unlinking a device keeps its origin, because later joiners need
its operations to rebuild the same tasks. The origin limit therefore counts
every device that has edited the task history, while the MLS group separately
limits how many devices are members at once to eight. A `hello` that carries
all 128 vector entries stays under 10 KiB, and every origin holds at least one
of the 10,000 retained operations.

The engine counts the slots in use: every origin its replica retains, plus one
slot for each current member, including this device, whether or not that
member has edited. It does not match members to origins, because a replica's
origin need not equal its member's device ID. A member that has already edited
therefore counts twice, which can refuse a device up to eight slots early; a
full group of eight still has room for at least 120 origins over its lifetime.
Linking needs one free slot for the other device.

Each device checks its own history before pairing starts, so
`createPrivateSync()`, `inviteToGroup()`, and `joinPrivateSync(url:)` or
`joinPrivateSync(phrase:)` fail with `SyncError.taskHistoryAtCapacity` and
nothing is linked.

The inviter then checks the union of both histories with everything the group
has already committed to. The count covers:

- its own retained origins;
- the origins named by operations and hellos it has received but not applied;
- every active reservation (described below);
- every origin in the joiner's response;
- one slot for each current member, each reserved device, and the joiner,
  which must also stay within eight.

Each origin counts once, however many of these sources name it. Any received
operation that the engine keeps without applying must add its origin to the
same set.

#### Reservations

A joiner's history reaches the log only after it joins, so before every Add
the inviter publishes a `reservation` for the joiner as an MLS application
message. The relay log orders all reservations. Every member saves each
reservation it receives in its checkpoint before it acknowledges the inbox,
and reservations survive restarts. The inviter:

1. checks when the response arrives, before it shows a safety code or creates
   a group;
2. after approval, synchronizes, commits pending removals, and checks again
   against every active reservation;
3. publishes its reservation and saves it before any Add. A linked inviter
   saves the attempt in its checkpoint before sending it, and the claim once
   the relay accepts it. A founding inviter, which has no checkpoint yet,
   saves it in `sync-v2-claims.json` right after it creates the group, and
   recovery after a crash moves it into the rebuilt checkpoint;
4. checks again, counting only reservations earlier in the log than its own;
5. adds the joiner, and checks once more after the Add.

Of any two reservations, the later one's check counts the earlier one, so two
devices whose histories do not fit together are never both admitted. If both
inviters refuse, both joiners stay unlinked, which is safe. A failed check
before the Add means the joiner gets no MLS leaf, Welcome, or relay write
access. A failed check after the Add removes the new member the same way the
inviter removes a joiner that declined during the Add. In every case the
inviter sends decision 2, both devices report `SyncError.taskHistoryAtCapacity`,
and every local task stays on both devices. Current members keep syncing. The
check after the Add still counts the origins and slots of later claims that
have already reached the inbox or roster, so the earlier inviter can also
refuse; that loses a joiner but never admits one that does not fit.

A reservation is a lease measured in MLS epochs, never wall-clock time. The
owner adds the joiner only while the group epoch is below the reservation's
epoch plus 8, checked in the same serialized step that prepares the Add. A competing commit discards a prepared Add instead of moving it
to a later epoch, so the Add can apply only within that window. A member that
has processed the window without seeing the joiner join knows the Add can no
longer happen and drops the reservation. A reservation counts while it is
leased, and for as long as its device is a member, regardless of lease or
release. It is dropped once its device leaves after joining, or once the
device's history covers its origins. When an owner refuses a joiner or none
of its Adds is accepted, it publishes a `release` for that one reservation.
A sync cycle also releases the device's own claims that no pairing will use:
the attempt was cancelled or the app restarted, the joiner never joined, the
lease still runs, and no Add is waiting to be sent. Only the owner can
release a claim, and a release never frees slots of a device that is a
member.

The relay can accept a reservation without its answer reaching the owner.
The log never returns a member's own messages to its inbox, so the owner's
MLS client records where each of its last 64 reservations landed, with a
SHA-256 digest of the plaintext. Other messages are not recorded and cannot
push a reservation out. Each sync cycle, also after a restart, first
delivers any message still pending, then turns each saved attempt into a
claim at the cursor where it landed and releases it as above. An attempt
that never landed is dropped, but never while its send is still running,
even after its pairing was cancelled. The owner starts no reservation while
an earlier attempt is unresolved.

If `sync-v2-claims.json` exists but does not decode, the founding inviter
never treats it as empty. It keeps the bytes as
`sync-v2-claims-unreadable.json`. When no member has been added yet, it
starts a new file. When recovery finds members it added, it counts each of
their histories as unknown: it refuses to invite or answer snapshot requests
until that member's next `hello` arrives, and the `hello`'s vector becomes
that member's claim. Such a member is also provisional, so one that never
sends a message is removed, and a member that leaves no longer blocks
invitations.

A new member cannot read reservations published before it joined. When the
inviter answers the new member's join `hello`, it sends a `reservations`
message for that member with every claim it holds. Only a member that has
its own snapshot answers, so a snapshot addressed to the new member is
complete as of the `hello` it answers. The new member merges claims by their
original log cursor. A known claim keeps its local state, and a release that
arrives before the snapshot is kept, so a late snapshot never undoes a
release or an admission. Members that already have their snapshot ignore
later ones. Until the snapshot arrives, the new member refuses to invite and
reports `SyncError.privateSyncUnreachable`. While it waits, it sends a new
`hello` naming the next member every five sync cycles, and at once if the
member it asked has left. This state survives restarts, including recovery
after an interrupted join or a request that was never sent.

Admission refuses while 16 or more claims are active. In normal use a group
of eight has far fewer. A checkpoint never drops an active claim below 64
stored claims. Past 64, it keeps 64, marks the checkpoint overflowed, passes
that flag on in snapshots, and refuses every further admission on that link.

A joiner that has already edited counts both as an origin and as a member, so
it can be refused one slot early. A device that edited the history before,
left, and links again still needs a free slot. Version 2 does not compact retired origins: a task history without a free
slot cannot gain another contributing device.

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
