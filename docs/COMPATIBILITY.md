# Protocol compatibility

These notes describe the wire formats that the current client and server
accept. Wire versions identify contracts between implementations.

## Protocol version 2

The current protocol is version 2. Groups are MLS groups (RFC 9420, ciphersuite
`MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519`) run through OpenMLS. Version 2
identifiers are:

- the `/v2/pairing` WebSocket room, whose registration and control messages
  carry `version: 2`;
- the `/v2/mls` HTTP delivery service, where every request and response
  carries `version: 2`;
- invitation URLs with `v=2`;
- HKDF and hash labels under `com.gotdone.sync/…/v2`;
- replication messages with `version: 2` inside MLS application messages;
- the `sync-v2.json` checkpoint and the `mls-v2` and `mls-v2-departing`
  storage directories.

The relay serves no `/v1` path. The delivery listener answers any `/v1` request
with HTTP 400 `unsupportedVersion`, `supportedVersions: [2]`, and a message
that tells the user to pair every device again. The pairing WebSocket closes a
`/v1` connection with code 1008 and the same message as the close reason.

## Supported contracts

| Artifact | Version | Validation and mismatch behavior |
| --- | --- | --- |
| WebSocket path and registration | `/v2/pairing`, `version: 2` | Relay closes any other path and rejects unsupported registration |
| Relay control JSON | `version: 2` | Client rejects unsupported control before acting on it |
| Invitation URL | Consumer-specific scheme and `pair` host with `v=2` | Parser requires `secret`, `group`, and `fingerprint`; `v=1` fails with `unsupportedVersion` |
| Invitation phrase | 17 words: 16-byte secret and a checksum word | Unknown words and a wrong checksum are rejected; the phrase carries no version |
| MLS pairing frames | Version 2 domains over the `/v2/pairing` WebSocket room | Frames that fail authentication or carry an unknown kind abort pairing; a response that does not open the commitment, or lacks a canonical origin list, aborts pairing |
| Group profile | GroupContext extension `0xF0D5`, descriptor format 1; profiled pairing frames 6 and 7, decision 3 | Any difference in descriptor bytes refuses pairing before a KeyPackage is published, refuses a Welcome, and stops sync of a stored group with `incompatibleGroupProfile`; a group without the extension is legacy |
| MLS delivery service | `/v2/mls`, `version: 2` | Client rejects any other response version; server answers other request versions with HTTP 400 `unsupportedVersion` |
| MLS delivery entry kinds | `commit`, `application`, `proposal` | Server rejects other kinds; a `proposal` revokes its sender |
| Replication message | `version: 2` inside MLS application messages | Receivers skip messages with another version or shape |
| Replication checkpoint | `sync-v2.json`, version 2 | Engine discards an unreadable checkpoint and rebuilds it from MLS state |
| Founding reservations | `sync-v2-claims.json` | Engine keeps an unreadable file as `sync-v2-claims-unreadable.json` and refuses to invite until each member it added reports its history |
| Replica archive | `replica-v1.json`, format 2 | New archives store a random origin for local operations. Format 1 archives still load and keep the device ID as origin; earlier clients refuse to load format 2 and stop with a local storage error until the app is updated again; the archive is not changed. Replica validation rejects unsupported archives and more than 128 origins |

The relay's `/healthz` reports `supportedVersions: [2]`.

## Breaking cutover from version 1

Version 2 replaces the custom version 1 protocol: its pairing handshake,
encrypted live frames, per-pair and group mailbox envelopes, signed membership
snapshots, and rekey records. Version 2 clients contain no version 1
implementation, so version 1 and version 2 devices cannot pair or sync with
each other.

**Every existing version 1 group must pair again.** On first launch, a version
2 client:

1. deletes the version 1 Keychain accounts (`active-pair-v1`,
   `active-group-v1`, `pending-pair-v1`, `mailbox-checkpoint-v1`, and the
   terminal pairing journals);
2. deletes leftover version 1 pairing staging files;
3. keeps the task replica unchanged;
4. reports `SyncError.relinkRequired` and starts unpaired.

No keys are migrated. Tasks reach the new group when the device pairs again,
because the joiner's replica merges into the group. Upgrade every device of a
group, then create a new link on one of them and invite the others.

## Server rollout

The relay serves only version 2: the `/v2/pairing` WebSocket room and
`/v2/mls`. The version 1 mailbox and its storage are gone, so version 1
clients that are still installed stop syncing as soon as the relay is
upgraded. Their users must update and pair again. Version 2 clients need no
change.

A relay that previously ran version 1 can delete its `mailbox.sqlite3`. The
delivery store now defaults to `relay-data/mls.sqlite3` and is selected with
`--database`; `--mailbox-*` options were replaced by `--delivery-host`,
`--delivery-port`, and `--delivery-max-connections`.

Production consumers must use the same relay origin for pairing and delivery.
`SyncConfiguration.relayURL` must end in `/v2/pairing` and
`SyncConfiguration.mailboxURL` in `/v2/mls`. The demo's application
identifier and Keychain service create an independent install; it does not
migrate another application's sandbox or credentials.

## Origin limit

Earlier version 2 builds accept at most eight origins in a replica, a version
vector, or a `hello`. Current builds accept 128 in either archive format,
with the same message shape. In a group that mixes builds, an earlier build rejects
operations from a ninth origin, so it misses that device's edits. It also
skips any `hello` with more than eight entries and does not answer it. Update
every device in a group before a ninth device edits its tasks. An earlier
build cannot open an archive with more than eight origins: it starts in the
failed phase with a too-many-origins error, leaves the archive in place, and
the tasks return after updating again.

## Pairing origin inventory

The pairing response now ends with the joiner's origin list, and decision
value 2 refuses a joiner whose history would not fit. Builds before this
change send a 96-byte response and accept only decision values 0 and 1.
Pairing between an earlier build and a current build therefore fails in
either direction before any safety code is shown: the inviter cannot read
the other build's response and reports `SyncError.invalidPairMessage`, then
declines, so the joiner reports `SyncError.pairingDeclined`. Devices that are already linked keep syncing; only new pairings
need every device updated.

Current builds also send `reservation`, `release`, and `reservations`
replication messages. Earlier builds skip them, so an earlier build neither
publishes nor counts reservations, and a device it invites never receives a
snapshot and cannot invite while that inviter stays in the group. Update
every device before inviting.

## Group profiles and ten members

Builds with group profiles add a descriptor to every group they create unless
the consumer keeps `SyncGroupProfile.legacyTaskDemo`, the default. Legacy
groups, the demo app, and pairing between legacy-mode engines behave as before:
eight members, the same frames, and the same commitment and safety-code
inputs. A profiled group admits up to its own limit, at most ten.

| Inviter | Joiner | Result |
| --- | --- | --- |
| Earlier build, or legacy mode | Earlier build, or legacy mode | Pairs as before; legacy group of eight |
| Profiled | Same descriptor | Pairs; the group stores the descriptor |
| Profiled | Earlier build | The joiner cannot read offer kind 6 and aborts; the inviter reports `pairingDeclined` or `invalidPairMessage` |
| Earlier build | Profiled | The joiner refuses offer kind 1 and sends decision 3; the earlier inviter reads decision 3 as an invalid frame and aborts |
| Profiled or legacy mode | The other mode | Both report `incompatibleGroupProfile` before any KeyPackage, approval, Add, or stored state |
| Profiled | Other application, schema, schema version, or member limit | Both report `incompatibleGroupProfile`, by URL and by phrase |
| Profiled | Descriptor rewritten in transit by a holder of the invitation | The commitment check fails with `invalidPairMessage` before approval, or the codes differ |

Existing members of a legacy group keep syncing after they update. An engine
whose configured profile differs from the profile of its stored group, in
either direction, stops sync with `incompatibleGroupProfile`, keeps the MLS
state, checkpoint, and tasks, and refuses to invite. Configuring the stored
profile again resumes sync. A settled founding group without other members is
discarded and replaced instead.

### Relay ceiling

The relay admits ten active writers per group and refuses an Add beyond that
with a journaled `keyPackageUnavailable`; the inviter then discards the Add at
once. Earlier relays admit eight and answer HTTP 429, which is not final. A
profiled inviter adding a ninth device through such a relay keeps the Add
pending and reports `privateSyncUnreachable`; the joiner reports
`pairingDeclined`. The inviter keeps receiving, but its own changes wait until
the KeyPackage expires, at most 15 minutes. The relay then refuses the Add for
good and the inviter discards it and catches up. The eight current members keep
syncing, and the relay keeps eight writers. Ten-device groups therefore need
the ten-writer relay. The current production relay release accepts eight.

### Ordered cleanup

Automatic removal of a provisional member, and the withdrawal a departing
inviter performs, use the `append-if-head` and `capabilities` delivery
operations. Relays without them answer both as invalid requests. A client then
removes nobody automatically. A device that was admitted but never spoke stays
a member until someone removes it with `removeDevice`, and a departing inviter
leaves without withdrawing its unspoken admissions. Explicit removal, leaving,
and every other delivery keep working on older relays. A cleanup Remove sent
unconditionally by an earlier build of this branch keeps its uncertain outcome;
it is delivered or superseded as before. If a relay is downgraded while a
conditional Remove is pending, that member keeps retrying it and sends nothing
else until the relay supports the operation again. An earlier build reopening
state with such a pending Remove ignores its `expectedHead` and sends it as an
ordinary append.

### Rollback

A group with more than eight members cannot move back to an eight-member
relay or to an earlier build:

- an earlier build validates every roster against eight members, so it stops
  with `syncHistoryBlocked` at the commit that adds a ninth member, and on
  every sync of state that already holds more than eight;
- an earlier build cannot join a profiled group or admit anyone to it, because
  its KeyPackages lack the profile capability and its pairing frames are
  legacy. It does not read profiles, so a downgraded member of a profiled
  group with at most eight members keeps exchanging messages;
- an earlier build refuses a saved reply file with more than eight recipients
  and stops sync with `localStorageUnavailable` without changing the file;
- an eight-writer relay refuses every Add while it holds eight or more active
  writers, so a group that already has nine or ten writers on a newer relay
  keeps them but can add no one.

No build truncates or evicts members to fit a smaller limit. To move a large
group back, remove members until eight remain, then downgrade, or unlink every
device and pair again under the earlier build.

## Future changes

Within version 2, preserve required fields, hash and HKDF labels, canonical
encoding, supported limits, and error meanings. Unknown pairing frame kinds and
delivery entry kinds are rejected, so a new kind needs coordinated client
support or a new protocol version. The server treats MLS messages as opaque and
does not negotiate application formats for clients.

A breaking format or cryptographic change requires a new version and endpoint
namespace. A change to the MLS ciphersuite or to OpenMLS state serialization
can make stored MLS state unreadable; test it against state written by the
previous release first.

## Frozen identifiers

The namespace `com.gotdone.sync` is protocol bytes, not a package name or
application configuration. Swift centralizes it in `ProtocolDomains.swift`;
the relay treats every MLS message as opaque and uses no protocol labels.
Preserve it through the final brand rename; changing it requires a protocol
version. Invitation URL schemes are outside the cryptographic wire contract.
Each consumer supplies its own scheme through `SyncConfiguration` and registers
it in its app. The engine rejects URLs with another scheme; the demo uses
`accountless-sync`.
