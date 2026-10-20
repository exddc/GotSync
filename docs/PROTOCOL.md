# GotSync protocol

Status: implemented task-sync protocol, transport/sync version 1 and pairing
completion version 2.

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
  is durably persisted; acknowledgement immediately stops serving the
  ciphertext and logically nulls its payload.
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
in this protocol. The safety code catches accidental cross-pairing and implementation
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
pairingVersion = 0x02
roleA = 0x41
roleB = 0x42
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
`synchronous=FULL`, enables connection-level `secure_delete`, and restricts the
database to mode `0600`. Aggregate metrics contain no route, authorization,
message-ID, or payload values.

The default process limits are 256 admitted live WebSocket connections and 128
rooms, including rooms with only one waiting peer, plus 64 concurrent mailbox
connections. A lone peer expires after fifteen minutes by default (aligned with
the product pairing window). The wait timer is
cancelled while two peers are present and starts again for the remaining peer
after `peerLeft`. These defaults are configurable at relay startup.

Relay capacity and route control failures use small text frames:

| Code | Meaning | WebSocket close |
| --- | --- | ---: |
| `routeFull` | A third socket attempted to join an existing route | 1008 |
| `relayBusy` | The global connection or room limit is full | 1013 |
| `waitingExpired` | A route had only one peer for the waiting TTL | 1008 |
| `rateLimited` | The source already holds its concurrent-socket limit | 1013 |

Per-source admission and rate limits run before registration. A handshake over
the connection-rate limit receives HTTP 429 with `Retry-After`; a handshake that
fails deployment admission receives HTTP 403. Mailbox and MLS requests receive
the same statuses with JSON bodies `{"error":"rateLimited"}` or
`{"error":"admissionDenied"}`. Rejected requests change no room, mailbox, or
delivery state, so a client may retry them unchanged after `Retry-After`.

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
<scheme>://pair?v=1&secret=<base64url>
```

The relay origin is configured independently and included in the authenticated
handshake transcript. The invitation is held in memory, expires after fifteen
minutes, is limited to one confirmed attempt, and is invalidated after a
normal successful pair, mismatch rejection, regeneration, or cancellation. It
is never logged or intentionally written to the pasteboard. Swift cannot
promise zeroization of every temporary copy.

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
  pairingVersion ||
  connectionID || HA.publicKey || nonceA || HB.publicKey || nonceB
)
```

`pairingVersion` is inside the authenticated transcript. A client without the
durable version-2 completion protocol derives a different transcript and fails
key confirmation before either device persists pairing state.

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

After confirmation, independent values are derived:

```text
pairRoot = HKDF-SHA256(sessionSecret,
  info: "com.gotdone.sync/pair-root/v1", 32)
pairID = HKDF-SHA256(sessionSecret,
  info: "com.gotdone.sync/pair-id/v1", 16)
```

A makes an encrypted provisioning document available containing:

- A's random device ID;
- the current replica archive, its version vector, and its SHA-256 hash;
- the protocol version.

B and A both reject a provisioning archive larger than 280 KiB. The document
is split into independently authenticated pairing-control envelopes that fit
the 64 KiB mailbox payload limit.

B leaves any existing local replica untouched while the host archive is staged.
This permits a phone with local tasks to join without accepting destructive
replacement. A previously linked B may already appear in A's version vector;
the staged replica resumes B's next local sequence immediately after that
imported frontier so re-linking cannot fork B's origin. The host archive is a
captured frontier; operations created after it remain in A's log and are sent
during normal reconciliation.

Pair completion is a durable, idempotent state machine:

1. B persists `waitingForProvision` as soon as the authenticated handshake
   completes. A mismatch or cancellation at this point seals and persists an
   authenticated abort record before pending state can be removed.
2. After approval, A snapshots the archive hash, persists
   `provisionMayHaveBeenStored`, and PUTs deterministic encrypted provision
   chunks. A restart recreates identical chunks from the locked local archive.
3. B fetches and authenticates every chunk, verifies the archive hash and host
   identity, and stages the archive atomically. An empty or byte-equivalent
   local replica can advance directly to `readyMayHaveBeenStored`. A differing
   non-empty replica instead persists
   `provisionStagedAwaitingMergeApproval` without sending ready.
4. If Keep Both is confirmed, B constructs the complete candidate in memory
   from the staged host frontier and its untouched local replica. Exact stable
   ID/title/completion matches are reused; local-only or conflicting visible
   tasks are recreated under deterministic IDs. The whole result must satisfy
   task, retained-operation, and origin limits. B writes the validated result
   to a protected prepared-merge file before persisting
   `readyMayHaveBeenStored` and PUTting deterministic ready. Any failure leaves
   the original local replica unchanged and the merge choice available.
5. A authenticates ready, checks once more for a precommit abort, persists the
   joiner identity and
   `commitMarkerMayHaveBeenStored`, then repeatedly PUTs the same encrypted
   commit marker. A saves active credentials only after the relay confirms the
   marker.
6. B checks for a host abort, fetches commit, atomically installs or validates
   the complete prepared replica, and saves active credentials.
7. B seals the deterministic receipt and persists it in the terminal-action
   journal before its first PUT. After a confirmed PUT, B can clear
   pending/staging while retaining that journal entry. A clears its pending
   record only after fetching and authenticating the receipt.
8. B continues republishing the journaled receipt across launches and relay
   retention. It removes the entry after a PUT reports that the exact sealed
   message was already acknowledged by A, or after a normal authenticated
   active sync session proves that the matching host completed pairing.

Every state is stored before the network action it describes may have happened.
An ambiguous response therefore causes the exact same authenticated envelope to
be retried. Both roles resume from Keychain and protected staging files after a
restart. Before ready, B can cancel while waiting for provision or merge
approval, and A can cancel while its provision state is still precommit. The
sender journals the sealed abort before clearing pending state. A checks a
joiner abort before accepting ready and again before commit publication; B
checks a host abort before accepting commit. An observed precommit abort takes
precedence over a racing ready record. After commit may have been published,
ordinary cancellation is hidden.

Before an abort recipient clears pending state, it persists the abort cursor
and sender identity in `abortAcknowledgementMayHaveBeenStored`. It recreates
the deterministic sealed abort, PUTs it to distinguish a live payload from an
acknowledged tombstone, ACKs when needed, and verifies a subsequent PUT reports
`acknowledged`. A crash or ambiguous ACK therefore resumes with the pair root
still available instead of leaving the sender's terminal proof stranded.

The protected staging archive remains the authenticated host baseline. A
separate protected prepared-merge archive contains the complete result approved
by B. Commit installation uses that complete file atomically; it never
recreates local tasks one at a time after the irreversible commit. Cleanup of
staging, prepared-merge, or backup files after success, cancellation, or a
later launch is best effort. Such orphans are not credentials and a deletion
failure cannot invalidate an active pair or disable the main replica.
New attempts use filenames scoped by their authenticated 16-byte pair ID, so
an undeletable artifact from an older attempt cannot be selected by a later
pairing. Legacy fixed filenames are cleanup-only compatibility artifacts. Full
erase enumerates only these exact names and canonical pair-ID suffixes before
reporting success, including artifacts whose pending Keychain record was
already cleared.

An upgrade can encounter a legacy pending record beside active credentials
because the earlier live-only flow could persist one side before completion.
That combination is deliberately not treated as active. The client clears the
current pair, pending record, and mailbox checkpoint, preserves tasks and the
install identity, and requires an explicit fresh link. A legacy pending record
without active credentials is rolled back with the same task-preserving
behavior.

Normal success and authenticated cancellation release invitation and ephemeral
references. An individual pairing-control ciphertext is retained only until
cleanup succeeds or the relay retention deadline expires. A durable terminal
journal may recreate the same sealed receipt or abort until the peer
acknowledges it. A normal authenticated active session is an additional
completion proof for a joiner's receipt.

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

`modeByte` is `syncMode (0x53)`. `direction` is the sender role byte:
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

Handshake and confirmation messages are a separate typed binary codec and are
never accepted as encrypted application frames. The binary handshake decoder
enforces exact field counts and lengths; application payloads are bounded and
their required/forbidden field combinations are checked after decoding.

Protocol limits:

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
| Relay lone-peer wait | 900 seconds (15 minutes) by default, configurable; must match app invitation TTL |
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
| Concurrent mailbox connections | 64 by default, configurable |

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

Durable encrypted pairing control uses independently derived authorization
values for provision, ready, commit/receipt, and abort, separated again by
sender role. All stages share one dedicated route namespace:

```text
route = SHA256(
  UTF8("com.gotdone.sync/pairing-control-route/v2") || authorization
)
```

The relay accepts exactly the ordinary mailbox and pairing-control route
namespaces. It computes both candidates and compares them in constant time;
routes derived from arbitrary labels are unauthorized.

For pairing stage `S` (`provision`, `ready`, `commit`, or `abort`) and sender
direction `D`, authorization, encryption root, and message-ID key use separate
HKDF labels under:

```text
com.gotdone.sync/pairing-control-{auth|encryption|message-id}/S/D/v2
```

The 16-byte pair ID is HKDF context. Canonical control records carry the wire
field `version` with value `2` and the pair ID. Ready and commit records also bind the
host ID, joiner ID, and archive hash. Abort binds its sender role and device ID.
Provision records bind the host ID, full archive byte count, archive hash,
chunk index, and chunk count. Chunks can arrive out of order, but the client
requires one complete, consistent set and verifies the reconstructed hash.

Each control record uses a keyed deterministic message ID and a message-specific
key. AAD binds app ID, pairing version, stage, sender role, pair ID, route, and
message ID. Retrying an ambiguous PUT therefore reproduces the same route,
message ID, ciphertext, and server receipt.

Abort and receipt senders retain an already sealed terminal action in a
`ThisDeviceOnly` Keychain journal before pending state is cleared. The journal
is keyed by `(pairID, actionKind)`, rejects conflicting duplicates, and is
bounded to 32 entries. A record contains protocol versions, pair ID, action
kind, roles/device IDs, route authorization, route, message ID, and ciphertext.
It deliberately contains neither `pairRoot` nor a plaintext record or
pairing-control encryption key. Reaching the bound refuses another pairing
attempt rather than discarding an unresolved proof.

While the app is active, journal actions are published immediately on launch or
foreground. Failed attempts use bounded exponential backoff; confirmed PUTs
are attempted again hourly so an expired or operationally purged relay copy is
eventually recreated. A journal action for the pair currently owned by the
primary finalizer is skipped to avoid two local state machines publishing it.
Idempotent PUT means every retry carries the same envelope.

Each successful PUT response includes `acknowledged`. It is `false` while the
relay still serves that exact ciphertext and `true` when the recipient has
durably acknowledged it and only its receipt tombstone remains. A terminal
receipt or abort is removed from the sender's journal only after this
capability-authorized proof; the sender then forgets the terminal route best
effort. A receipt can also retire after the same joiner credentials complete a
normal PSK-authenticated active handshake and install their secure session.
Relay acceptance, `peerReady`, or an unauthenticated socket is not completion
proof. Unlink-and-keep preserves unresolved terminal entries and their
republisher.

If the terminal journal cannot be decoded, its raw bytes are not deleted. An
active joiner retains the 32-byte pairing archive hash in its device-only
credentials, allowing the app to reconstruct the deterministic sealed receipt,
quarantine the damaged bytes under a separate Keychain account, and replace
the active journal atomically. If reconstruction is impossible, the current
local replica and valid active credentials remain intact, but the UI requires
sync repair and blocks another pairing attempt until the user explicitly keeps
their tasks and resets the old sync recovery history, or performs full erase.

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
would also collide a 256-bit keyed HMAC and is treated as outside the protocol's
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
idempotent on `(route, messageID)`: identical bytes return the original cursor
and an `acknowledged` Boolean; different bytes return a conflict. The Boolean
is false for a live payload and true after an ACK has logically removed it.
The relay assigns monotonically increasing opaque cursors. Fetch is ordered and
non-destructive. The recipient:

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
The first live message starts a fixed deadline for its directional queue.
Later unique appends inherit that deadline, preventing both an origin-sequence
gap inside the queue and indefinite retention through continuous writes. Once
the live queue is empty, its next message starts a fresh deadline. Fetching
does not extend retention. Explicit erase or unlink best-effort forgets both
directions; expiry is the fallback.

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

These rules describe only the sample schema. A richer task model's correlated
completion date and status need one compound register; habit completion
history needs set/map semantics; ordering needs rank or sequence semantics; notifications are
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

The engine retains the complete operation log and all tombstones. Production needs
snapshot compaction, a cryptographic snapshot hash, atomic installation, and a
causal watermark proving that every authorized device can discard old history.

## Performance choices

- One persistent WebSocket while the app is active.
- No polling or batching delay on the live path.
- A separate two-second foreground mailbox poll, plus immediate cycles on edit,
  launch, and foregrounding.
- Outbound upload and inbound fetch are attempted independently so a capacity
  or service failure in one direction does not starve valid progress in the
  other.
- Immediate local UI application.
- Immediate single-operation send for interactive edits.
- Deterministic mailbox retries avoid a local ciphertext outbox while the
  operation log and Keychain upload checkpoint remain authoritative.
- One actor or serial executor owns every socket send.
- One connection-scoped outbound drain preserves local origin order; a stale
  send failure cannot cancel a replacement socket.
- Binary encrypted frames and disabled WebSocket compression.
- Bounded frame, queue, operation-batch, task-count, and title-size limits.
- Bounded catch-up operation batches are sent before later live edits.
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
different bounds in this protocol: the client gives WebSocket opening five seconds,
and the relay expires a lone registered peer after fifteen minutes by default. The
cryptographic handshake has no separate per-message deadline yet. `peerLeft`,
authentication failure, sequence failure, WebSocket closure, app suspension,
or timeout destroys the connection's ephemeral keys, traffic keys, counters,
pending sends, and socket state. Durable operations stay in the replica.

While foregrounded, reconnect uses exponential backoff with jitter, capped at
five seconds for the local development. A fresh connection always uses a new connection
ID, keys, nonces, transcript, traffic keys, nonce prefixes, and counters.
The client keeps at most one outstanding encrypted eight-byte ping ID. It sends
one when none is pending, checks every two seconds, and cancels the socket when
the pending ping is older than six seconds. Returning to the active scene
restarts at `registering`; entering the background closes intentionally.

The stable `syncRoute` lets the relay link this pair's foreground sessions over
time. This is accepted and disclosed protocol metadata. A production route-rotation
scheme must be recoverable on both sides before it can safely reduce that
linkability.

The mailbox loop is independent of live connection state. A successful mailbox
upload means "durably stored for delivery," not "applied by the peer." A
successful inbound ACK means this device durably applied the page. The engine does
not yet send an encrypted peer receipt back to advance a sender-visible
`peerAppliedVector`.

## Production gaps

Before production:

- replace or audit the custom handshake composition and publish test vectors;
- inject real Release `wss://` and `https://` endpoints, validate them on
  physical devices, and retain the current fail-closed build validation;
- add an anonymous admission mechanism with meaningful scarcity before
  exposing the capability-authorized relay publicly;
- require certificate validation, rate limits, and scrubbed proxy logs;
- require `https://` for the mailbox, encrypted database backups, storage
  monitoring, and a reviewed deletion/forensics policy for SQLite pages, WAL,
  snapshots, and backups;
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
- add deterministic recurrence IDs and field-appropriate CRDTs for richer task
  models;
- implement content-addressed blob transfer separately from operations;
- replace whole-archive JSON rewrites and linear lookups with an indexed
  SQLite/WAL store after measuring local commit and durable remote-ack latency
  near the retained-log limit;
- add an explicit encrypted export/recovery product decision;
- re-evaluate App Store encryption declarations.

## Version compatibility

See [COMPATIBILITY.md](COMPATIBILITY.md) for the version matrix and deployment order. Every new mailbox request carries `version: 1`; legacy requests that omit it are interpreted as version 1. Unsupported explicit versions return HTTP 400 `unsupportedVersion` before storage changes.

## Multi-device groups

Groups contain up to eight members. Founding two-member groups use the live two-socket room and durable mailbox. Groups with three or more members deliver operations through per-recipient mailboxes. A relay room accepts at most two sockets by default, independently of the group-size limit. Membership snapshots use signed version 2 records; the shared-root and signing-key limitations are documented in THREAT-MODEL.md and SECURITY-RED-TEAM.md.
