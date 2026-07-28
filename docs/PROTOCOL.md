# Got Done Relay proof-of-concept protocol

Status: implemented proof of concept, experimental protocol version 1.

This document describes the current implementation. The code and test vectors
must stay consistent with it. The construction uses standard CryptoKit
primitives, but the composition has not received an independent security audit
and must not be treated as production cryptography.

## Goals and invariants

- The relay never receives a task title, completion value, long-term pair root,
  or plaintext device identifier.
- The relay persists only independently authenticated ciphertext envelopes,
  opaque mailbox routes, cursors, hashes, and expiry metadata.
- The recipient acknowledges an envelope only after its local replica update
  is durably persisted; acknowledgement immediately removes its ciphertext.
- A phrase or QR is a one-time 128-bit random invitation.
- The existing device approves a live join after both devices show the same
  safety code.
- A successful pair produces distinct roles and a pair root stored only in each
  device's Keychain.
- Every normal connection derives fresh directional traffic keys.
- Application writes are locally durable before transmission.
- A stored-envelope retry is byte-identical and idempotent.
- Applying the same operation set in any order produces the same visible tasks.

## Threat model

The protocol is designed against:

- an honest-but-curious relay;
- a passive network observer when production TLS is used;
- an active relay that replays, delays, reorders, injects, or drops frames;
- stale invitation replay after a successful pair;
- duplicate application operations;
- wall-clock skew between devices.

It cannot prevent:

- denial of service by the relay or network;
- content access after a device itself is compromised;
- a photographed or deliberately shared invitation from being used while it is
  live;
- IP address, timing, duration, byte-count, and room-co-membership observation
  by the relay;
- stable directional mailbox-route, cursor, retention, and acknowledgement
  timing observation by the relay;
- data loss when every replica carrying the only copy of an update is lost;
- delivery of an edit that never reached the relay before its only source went
  offline;
- continuous foreground socket execution or guaranteed background upload after
  iOS suspends or force-quits the app;
- forward secrecy for ciphertext retained in the mailbox: later compromise of
  the pair root can decrypt retained envelopes.

Possession of a live invitation is treated as authorization to attempt pairing
in this POC. The safety code catches accidental cross-pairing and implementation
errors, but it does not prove physical proximity and cannot rescue a deliberately
shared or photographed invitation. The client runs one pairing attempt for each
live invitation, and the relay admits at most two sockets per route. Production
proximity enforcement requires a local channel such as BLE, NFC, or a
user-verified local-network exchange.

## Primitive suite

| Purpose | Primitive |
| --- | --- |
| Random values | `SecRandomCopyBytes` |
| Ephemeral agreement | X25519 |
| Extraction and domain separation | HKDF-SHA256 |
| Explicit key confirmation | HMAC-SHA256 |
| Payload encryption | ChaCha20-Poly1305 |
| Digests and safety code | SHA-256 |
| Secret persistence | iOS Keychain, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` |

All integer wire values are unsigned big-endian. Every derivation label begins
with `com.gotdone.sync/` and includes a protocol version.

Protocol constants:

```text
appID = UTF8("com.gotdone.relay.poc")
version = 0x01
roleA = 0x41
roleB = 0x42
pairMode = 0x50
syncMode = 0x53
mailboxMode = 0x4d
```

Transcript fields are encoded as `fieldTag(UInt8) || length(UInt32) || bytes`.
Fields appear exactly in the specified order and a field tag may occur only
once. HKDF uses an empty salt unless a salt is explicitly named. JSON
application messages use UTF-8, sorted keys, no insignificant whitespace, and
reject unknown protocol versions. A canonical relay origin is lowercase
scheme and host plus an explicit port, with no path, query, fragment, user
information, or trailing slash.

## Relay transport

Clients connect to a generic `/v1` WebSocket endpoint. The room token is sent in
the first registration message instead of a URL, query string, cookie, or
header that common access logs retain.

Registration is a small text frame:

```json
{"type":"register","version":1,"route":"base64url-32-bytes"}
```

The server:

1. validates size and shape;
2. joins the socket to the volatile route;
3. admits no more than two sockets;
4. emits text control frames such as `peerReady` and `peerLeft`;
5. forwards later binary frames unchanged to the other socket;
6. destroys an empty room immediately;
7. never buffers a client frame before the second peer exists.

The separate HTTP mailbox is durable and does not alter these live-room rules.
It listens on `/v1/mailbox/*`, accepts only JSON `POST` bodies, and never places
mailbox credentials in a URL. The default SQLite store uses WAL journaling and
`synchronous=FULL`. Aggregate metrics contain no route, authorization,
message-ID, or payload values.

The default process limits are 256 admitted live WebSocket connections and 128
rooms, including rooms with only one waiting peer. A lone peer expires after
two minutes by default. The wait timer is cancelled while two peers are present and
starts again for the remaining peer after `peerLeft`. These defaults are
configurable at relay startup.

Relay capacity and route control failures use small text frames:

| Code | Meaning | WebSocket close |
| --- | --- | ---: |
| `routeFull` | A third socket attempted to join an existing route | 1008 |
| `relayBusy` | The global connection or room limit is full | 1013 |
| `waitingExpired` | A route had only one peer for the waiting TTL | 1008 |

Only aggregate process counters are exposed. Metrics and logs contain no route,
IP, user agent, device ID, or payload.

## Invitation

The host generates 16 random bytes and one checksum byte:

```text
checksum = SHA256(invitation)[0]
```

The manual representation maps the 17 bytes to 17 words from a fixed 256-word
list. The QR carries the same 16-byte invitation in a versioned URL:

```text
gotdone://pair?v=1&secret=<base64url>
```

The relay origin is configured independently and included in the authenticated
handshake transcript. The invitation is held in memory, expires after two
minutes, is limited to one confirmed attempt, and is invalidated after a
normal successful pair or cancellation. It is never logged. If the user taps
Copy, the app writes it to the local-only pasteboard with a two-minute
expiration; Universal Clipboard is disabled for that item. Otherwise it is not
intentionally persisted. Swift cannot promise zeroization of every temporary
copy.

Derived values:

```text
pairRoute = HKDF-SHA256(invitation, info:
  "com.gotdone.sync/pair-route/v1", 32)

pairPSK = HKDF-SHA256(invitation, info:
  "com.gotdone.sync/pair-psk/v1", 32)
```

## Pairing handshake

Host is role A and joiner is role B.

After `peerReady`:

1. A generates ephemeral X25519 key `HA`, 16-byte `connectionID`, and 16-byte
   `nonceA`.
2. A sends `AHello` with those public values.
3. B generates ephemeral X25519 key `HB` and 16-byte `nonceB`.
4. Both serialize the transcript with exact, length-prefixed fields:

```text
T = SHA256(
  appID || version || canonicalRelayOrigin || pairRoute ||
  connectionID || HA.publicKey || nonceA || HB.publicKey || nonceB
)
```

5. Both calculate:

```text
DH = X25519(localEphemeralPrivate, remoteEphemeralPublic)
sessionSecret = HKDF-SHA256(DH, salt: pairPSK,
  info: "com.gotdone.sync/handshake/v1" || T, 32)
confirmKey = HKDF-SHA256(sessionSecret,
  info: "com.gotdone.sync/confirm/v1", 32)
```

6. B sends its public values and `HMAC(confirmKey, "B" || T)`.
7. A verifies in constant time and sends `HMAC(confirmKey, "A" || T)`.
8. Both display the same six-digit safety code derived from
   `HMAC(sessionSecret, "com.gotdone.sync/safety-code/v1" || T)`.
9. A waits for explicit user approval.

After approval, independent values are derived:

```text
hostToJoiner = HKDF-SHA256(sessionSecret,
  info: "com.gotdone.sync/pair-traffic/A-to-B/v1", 32)
joinerToHost = HKDF-SHA256(sessionSecret,
  info: "com.gotdone.sync/pair-traffic/B-to-A/v1", 32)
pairRoot = HKDF-SHA256(sessionSecret,
  info: "com.gotdone.sync/pair-root/v1", 32)
pairID = HKDF-SHA256(sessionSecret,
  info: "com.gotdone.sync/pair-id/v1", 16)
pairAtoBNoncePrefix = HKDF-SHA256(sessionSecret,
  info: "com.gotdone.sync/pair-nonce/A-to-B/v1", 4)
pairBtoANoncePrefix = HKDF-SHA256(sessionSecret,
  info: "com.gotdone.sync/pair-nonce/B-to-A/v1", 4)
```

A sends an encrypted provisioning document containing:

- A's random device ID;
- the current replica archive, its version vector, and its SHA-256 hash;
- the protocol version.

B and A both reject a provisioning archive larger than 280 KiB. This leaves
space for its encrypted application envelope under the separate 384 KiB
plaintext-frame limit.

B must have an empty replica in this two-device POC. It rejects provisioning
without modifying local data if it has any task, operation, tombstone, or
credentials from another chain. The host archive is a captured frontier;
operations created after that frontier remain in A's log and are sent during
normal reconciliation.

Pairing payloads use the encrypted-frame construction below with the pair
direction's nonce prefix, a fresh counter beginning at zero in each direction,
and the exact AAD defined below with `modeByte = pairMode (0x50)`.

Pair completion is staged, but the POC does not claim crash-atomic or fully
recoverable commit:

1. Before A sends provisioning, it atomically persists `pendingPair` containing
   pair ID, root, role, archive hash, and expiry.
2. B verifies and atomically stages the archive plus its own `pendingPair`
   before sending `ready(archiveHash, deviceID)`.
3. A verifies the request, saves active credentials,
   and sends `commit(pairID)`.
4. B saves active credentials and clears its pending record only after
   `commit`, then sends `commitReceipt(pairID)`.
5. A deletes its pending record after the receipt.

Cancellation or terminal failure before active credentials exist clears the
pending record. For a joiner, it also deletes the staged replica archive and
recreates an empty local replica before clearing the pending marker, so a crash
retries rollback instead of orphaning imported data. Launch applies the same
rule: a pending record without active credentials is rolled back, never
silently promoted. Each in-memory attempt has a generation token checked after
suspension points and before durable activation, so a canceled attempt cannot
activate or overwrite a newer attempt. Existing active credentials take
precedence and start normal reconnection.

No two-device exchange can make both commits crash-atomic. A crash or transport
failure after A saves active credentials but before B saves active credentials
can therefore leave A paired while B rolls back. This POC has no recovery
exchange for that split and requires a local reset and a new pairing on both
devices. Production needs a resumable, idempotent `ready`/`commit` protocol
covering this boundary, including an empty initial archive.

Normal successful completion and explicit cancellation release invitation and
ephemeral references.

## Normal connection handshake

The room is derived from the pair root:

```text
syncRoute = HKDF-SHA256(pairRoot,
  info: "com.gotdone.sync/route/v1", 32)

syncPSK = HKDF-SHA256(pairRoot,
  info: "com.gotdone.sync/connection-psk/v1", 32)
```

Every connection repeats the A/B ephemeral handshake with a new connection ID,
nonces, and X25519 keys. `syncPSK` replaces `pairPSK`. Long-term device IDs and
pair ID are included in the authenticated transcript but not sent to the relay
as registration metadata.

The two role-ordered device IDs are already known locally and are not fields in
either cleartext hello. A peer public key that cannot be decoded, produces a
key-agreement error, or yields an all-zero shared result is rejected.

The normal transcript is:

```text
T = SHA256(
  appID || version || canonicalRelayOrigin || syncRoute || pairID ||
  roleADeviceID || roleBDeviceID || connectionID ||
  HA.publicKey || nonceA || HB.publicKey || nonceB
)
```

The connection derives:

```text
AtoBKey = HKDF-SHA256(sessionSecret,
  info: "com.gotdone.sync/traffic/A-to-B/v1", 32)
BtoAKey = HKDF-SHA256(sessionSecret,
  info: "com.gotdone.sync/traffic/B-to-A/v1", 32)
AtoBNoncePrefix = HKDF-SHA256(sessionSecret,
  info: "com.gotdone.sync/nonce/A-to-B/v1", 4)
BtoANoncePrefix = HKDF-SHA256(sessionSecret,
  info: "com.gotdone.sync/nonce/B-to-A/v1", 4)
```

## Encrypted frames

Each direction owns an independent sequence beginning at zero for a fresh
connection. A nonce is the four-byte directional prefix followed by the
eight-byte sequence.

```text
frame = version(1) || sequence(8) || ciphertext || tag(16)
```

Authenticated associated data contains:

```text
version(1) || transcriptHash(32) || modeByte(1) ||
direction(1) || UInt64BE(sequence)(8)
```

`modeByte` is `pairMode (0x50)` for provisioning frames and `syncMode (0x53)`
for normal synchronization frames. `direction` is the sender role byte:
`roleA (0x41)` for host-to-joiner or `roleB (0x42)` for joiner-to-host. There is
no literal string in the AAD.

The deterministic sync-frame vector checked by the security suite is:

```text
key = 55 repeated 32 bytes
noncePrefix = 66 repeated 4 bytes
transcriptHash = 77 repeated 32 bytes
modeByte = 53
direction = 41
sequence = 0000000000000000
plaintext = 68656c6c6f
frame = 0100000000000000004ac77b4a4f6cc6626af0cb56075d1d76e5e24a1f1c
```

The nonce is reconstructed and is not transmitted separately. A receiver
requires exactly the next sequence. Duplicate, gap, malformed, oversized, or
unauthentic frames close the session. Application operation sequence numbers
are never reused as cipher nonces.

The same rules apply to pairing payload frames using pair-specific keys,
prefixes, transcript, and the pair mode byte. A counter is checked before
increment and the connection closes instead of wrapping at `UInt64.max`.

Handshake and confirmation messages are a separate typed binary codec and are
never accepted as encrypted application frames. The binary handshake decoder
enforces exact field counts and lengths; application payloads are bounded and
their required/forbidden field combinations are checked after decoding.

POC limits:

| Value | Limit or default |
| --- | --- |
| Registration frame | 512 bytes |
| Binary WebSocket message | 512 KiB |
| Decrypted application message | 384 KiB |
| Initial provisioning archive | 280 KiB |
| Operations per batch | 256 |
| Canonically encoded operation array | 256 KiB |
| Task title | 200 Unicode scalars and 512 UTF-8 bytes |
| Materialized tasks including tombstones | 1,000 |
| Retained operations | 10,000 |
| Version-vector origins | 8 |
| Relay sockets per route | 2 |
| Relay live sockets | 256 by default, configurable |
| Relay rooms | 128 by default, configurable |
| Relay lone-peer wait | 120 seconds by default, configurable |
| Per-socket forwarding queue | 16 frames or 1 MiB |
| Relay registration deadline | 5 seconds |
| Client WebSocket open deadline | 5 seconds |
| Stored mailbox envelope | 64 KiB including AEAD tag |
| Mailbox append batch | 128 envelopes |
| Client mailbox fetch page | 64 envelopes |
| Mailbox request or serialized response | 512 KiB |
| Mailbox unacknowledged retention | 365 days by default |
| Mailbox receipts per directional route | 10,000 by default |
| Mailbox live ciphertext per directional route | 64 MiB by default |

## Asynchronous encrypted mailbox

Connection-bound live frames cannot be stored for a later session: their keys,
nonce prefixes, counters, and associated data belong to one ephemeral
handshake. Offline delivery therefore encrypts each immutable task operation
again with independent, session-stable mailbox material.

Each direction has a separate mailbox. For sender role `A` use direction label
`A-to-B`; for role `B` use `B-to-A`:

```text
authorization = HKDF-SHA256(pairRoot,
  info: "com.gotdone.sync/mailbox-auth/" || direction || "/v1", 32)

route = SHA256(
  UTF8("com.gotdone.sync/mailbox-route/v1") || authorization
)

encryptionRoot = HKDF-SHA256(pairRoot,
  info: "com.gotdone.sync/mailbox-encryption/" || direction || "/v1", 32)

messageIDKey = HKDF-SHA256(pairRoot,
  info: "com.gotdone.sync/mailbox-message-id/" || direction || "/v1", 32)
```

The server verifies `route` from `authorization` on every request and stores
neither the authorization value nor its pair root. Host-to-joiner and
joiner-to-host routes are different. A device appends only to its outbound
route and fetches/acknowledges only its inbound route.

For canonical operation bytes `P`:

```text
messageID = HMAC-SHA256(messageIDKey, P)

messageKey = HKDF-SHA256(encryptionRoot,
  info: "com.gotdone.sync/mailbox-message-key/v1" || messageID, 32)

nonce = 000000000000000000000000
payload = ChaCha20-Poly1305(messageKey, nonce, P, AAD).ciphertext || tag
```

The all-zero nonce is safe here because every distinct, immutable operation
gets a distinct pseudorandom `messageKey`; it is not reused under one key.
Repeating the same operation intentionally reproduces the same key, nonce, AAD,
and ciphertext so an ambiguous network retry is exact. A message-ID collision
would also collide a 256-bit keyed HMAC and is treated as outside the POC's
practical failure model.

Mailbox AAD is the normal tagged transcript encoding:

| Tag | Value |
| ---: | --- |
| 1 | `appID` |
| 2 | protocol version |
| 3 | `mailboxMode` |
| 4 | 16-byte pair ID |
| 5 | sender role byte |
| 6 | 32-byte directional route |
| 7 | 32-byte message ID |

After decryption the recipient re-encodes the operation canonically, recomputes
the HMAC message ID in constant time, and verifies that its origin is the
paired remote device.

The HTTP contract is:

```text
POST /v1/mailbox/put
  {route, auth, messages: [{id, payload}]}

POST /v1/mailbox/fetch
  {route, auth, after, limit}

POST /v1/mailbox/ack
  {route, auth, cursor}

POST /v1/mailbox/forget
  {route, auth}
```

Binary fields are canonical unpadded base64url. `put` is transactionally
idempotent on `(route, messageID)`: identical bytes return the original cursor;
different bytes return a conflict. The relay assigns monotonically increasing
opaque cursors. Fetch is ordered and non-destructive. The recipient:

1. fetches a bounded page;
2. authenticates and validates every envelope;
3. atomically applies and persists the operations;
4. acknowledges inclusively through the page's last cursor.

A crash before step 3 leaves the replica unchanged. A crash after step 3 but
before step 4 redelivers byte-identical operations, which the replica accepts
as no-ops. ACK nulls ciphertext immediately but retains the message ID and
ciphertext hash until expiry, so a sender retry after a lost response cannot
resurrect already-consumed data.

The sender uploads local-origin operations in contiguous sequence order. Only
after a successful `put` does it save the highest uploaded sequence in the
ThisDeviceOnly Keychain. Failure before that checkpoint resends the same
deterministic envelopes. The operation log remains the durable source of
truth.

The client uploads immediately after each local edit and polls approximately
every two seconds while active, with bounded failure backoff. Entering the
background requests one best-effort flush using iOS background execution time;
there is no APNs wake-up and force-quit upload is not promised. Launch or
foregrounding immediately uploads and polls.

Unacknowledged ciphertext and its receipts expire after 365 days by default.
A new unique append extends the whole unacknowledged directional queue to the
same expiry, preventing an origin-sequence gap inside an active queue.
Fetching does not extend retention. Explicit local reset best-effort forgets
both directions; expiry is the fallback.

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
UUID in this POC. Restoring an item creates a new UUID.

Each replica persists:

- materialized task records and tombstones;
- every operation;
- its next local origin sequence;
- its Lamport clock;
- the highest contiguous sequence seen for each origin.

An install-scoped 128-bit replica device ID is generated on first launch,
before any task or pairing operation, and stored with a `ThisDeviceOnly`
Keychain class. It is not regenerated when a chain is left. Origin sequences
begin at one; zero means that no operation from an origin has been applied.
If the install identity or persistent replica cannot be opened, the app enters
a fatal local error state: it does not restore pair credentials, connect,
accept edits, or acknowledge remote operations through an in-memory fallback.

A local edit atomically persists the operation, materialized state, next origin
sequence, Lamport clock, and local vector before it is sent. A remote batch
atomically persists every accepted operation, materialized state, updated
vectors, and `lamport = max(localLamport, receivedLamport)` before an
acknowledgement. The sample achieves this by atomically replacing one complete
replica archive.

Operations are idempotent by `(originDeviceID, originSequence)`. A repeated ID
must have byte-identical canonical content; different content for an existing
ID is a fork and closes the session.

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

These rules describe only the sample schema. Got Done's correlated completion
date and status need one compound register; habit completion history needs
set/map semantics; ordering needs rank or sequence semantics; notifications are
derived local state; images need a blob path; recurring occurrences need
deterministic IDs.

## Reconciliation

After the encrypted connection becomes ready, both peers exchange version
vectors. Each sends the locally retained operations whose origin sequence is
greater than the peer's watermark.

The connection captures a reconciliation frontier after receiving the peer
vector. Missing operations are grouped by origin and sent in origin-ID order,
then ascending origin sequence. A greedy byte-aware batcher computes each
canonical operation's encoded size once and closes a batch before either 256
operations or 256 KiB would be exceeded. This prevents a count-valid batch with
large escaped strings from exceeding the byte bound without repeatedly
re-encoding the growing batch. The single send serializer places complete
catch-up batches ahead of live operations created afterward. Live edits remain
locally durable and queued until that barrier is emitted. The receiver rejects
a gap within an origin, closes, and retries reconciliation rather than
buffering an unbounded origin-sequence gap. Operations from another origin may
legitimately expose the hidden partial-record behavior described above.

The receiver:

1. validates bounds and ordering;
2. applies operations deterministically;
3. persists the updated replica;
4. sends an acknowledgement containing its version vector.

An acknowledgement is emitted only after persistence. Round-trip latency is
not currently recorded per operation. A batch is durably covered when the
returned vector for every included origin is at least its highest included
sequence. Duplicate acknowledgements and a lost acknowledgement are harmless;
reconnect vectors provide the durable truth. The RTT displayed by the sample UI
is instead the encrypted ping/pong round trip.

The POC retains the complete operation log and all tombstones. Production needs
snapshot compaction, a cryptographic snapshot hash, atomic installation, and a
causal watermark proving that every authorized device can discard old history.

## Performance choices

- One persistent WebSocket while the app is active.
- No polling or batching delay on the live path.
- A separate two-second foreground mailbox poll, plus immediate cycles on edit,
  launch, and foregrounding.
- Immediate local UI application.
- Immediate single-operation send for interactive edits.
- Deterministic mailbox retries avoid a local ciphertext outbox while the
  operation log and Keychain upload checkpoint remain authoritative.
- One actor or serial executor owns every socket send.
- One connection-scoped outbound drain preserves local origin order; a stale
  send failure cannot cancel a replacement socket.
- Binary encrypted frames and disabled WebSocket compression.
- Bounded frame, queue, operation-batch, task-count, and title-size limits.
- Missing history is sent before large snapshots.
- A future burst path may coalesce for 5-10 ms or 32-64 KiB without delaying a
  single interactive edit.

## Foreground connection state machine

```text
disconnected
  -> registering
  -> waitingPeer
  -> handshaking
  -> reconciling
  -> live
  -> backoff
  -> registering
```

Role A is the only hello initiator. Registration, peer wait, and handshake have
different bounds in this POC: the client gives WebSocket opening five seconds,
and the relay expires a lone registered peer after two minutes by default. The
cryptographic handshake has no separate per-message deadline yet. `peerLeft`,
authentication failure, sequence failure, WebSocket closure, app suspension,
or timeout destroys the connection's ephemeral keys, traffic keys, counters,
pending sends, and socket state. Durable operations stay in the replica.

While foregrounded, reconnect uses exponential backoff with jitter, capped at
five seconds for the local POC. A fresh connection always uses a new connection
ID, keys, nonces, transcript, traffic keys, nonce prefixes, and counters.
The client keeps at most one outstanding encrypted eight-byte ping ID. It sends
one when none is pending, checks every two seconds, and cancels the socket when
the pending ping is older than six seconds. Returning to the active scene
restarts at `registering`; entering the background closes intentionally.

The stable `syncRoute` lets the relay link this pair's foreground sessions over
time. This is accepted and disclosed POC metadata. A production route-rotation
scheme must be recoverable on both sides before it can safely reduce that
linkability.

The mailbox loop is independent of live connection state. A successful mailbox
upload means "durably stored for delivery," not "applied by the peer." A
successful inbound ACK means this device durably applied the page. The POC does
not yet send an encrypted peer receipt back to advance a sender-visible
`peerAppliedVector`.

## Production gaps

Before production:

- replace or audit the custom handshake composition and publish test vectors;
- require `wss://`, certificate validation, rate limits, and scrubbed proxy logs;
- require `https://` for the mailbox, encrypted database backups, storage
  monitoring, and a reviewed deletion/forensics policy for SQLite pages, WAL,
  snapshots, and backups;
- implement resumable, idempotent pairing recovery across the final two-device
  commit boundary;
- add explicit per-message deadlines to the cryptographic handshake;
- add signed per-device membership and authenticated revocation;
- rotate a key epoch after device removal;
- add malformed-frame fuzzing and nonce-reuse tests;
- design background wake-up metadata consciously rather than pretending iOS
  permits a permanent socket;
- decide whether APNs wake-up tokens fit the product's no-tracking promise;
- replace or independently audit deterministic stored-envelope derivation,
  add published cross-language vectors, and design mailbox key epochs for
  forward secrecy and device revocation;
- add encrypted peer receipts if the UI must distinguish server acceptance from
  remote-device application;
- consider ciphertext padding if message-size leakage is unacceptable;
- add deterministic recurrence IDs and field-appropriate CRDTs for Got Done;
- implement content-addressed blob transfer separately from operations;
- replace whole-archive JSON rewrites and linear lookups with an indexed
  SQLite/WAL store after measuring local commit and durable remote-ack latency
  near the retained-log limit;
- add an explicit encrypted export/recovery product decision;
- re-evaluate App Store encryption declarations.
