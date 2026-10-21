# Protocol compatibility

These notes describe the wire formats that the current client and server
accept. Wire versions identify contracts between implementations.

## Protocol version 2

The current protocol is version 2. Groups are MLS groups (RFC 9420, ciphersuite
`MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519`) run through OpenMLS. Version 2
identifiers are:

- the `/v2/mls` HTTP delivery service, where every request and response
  carries `version: 2`;
- invitation URLs with `v=2`;
- HKDF and hash labels under `com.gotdone.sync/…/v2`;
- replication messages with `version: 2` inside MLS application messages;
- the `sync-v2.json` checkpoint and the `mls-v2` and `mls-v2-departing`
  storage directories.

Pairing frames still travel through the version 1 WebSocket room at `/v1`. The
room only forwards opaque binary frames between two sockets, so its
registration and control messages keep `version: 1`.

## Supported contracts

| Artifact | Version | Validation and mismatch behavior |
| --- | --- | --- |
| WebSocket path and registration | `/v1`, `version: 1` | Relay rejects unsupported registration and closes the socket |
| Relay control JSON | `version: 1` | Client rejects unsupported control before acting on it |
| Invitation URL | Consumer-specific scheme and `pair` host with `v=2` | Parser requires `secret`, `group`, and `fingerprint`; `v=1` fails with `unsupportedVersion` |
| Invitation phrase | 17 words: 16-byte secret and a checksum word | Unknown words and a wrong checksum are rejected; the phrase carries no version |
| MLS pairing frames | Version 2 domains over the `/v1` WebSocket room | Frames that fail authentication or carry an unknown kind abort pairing; a response that does not open the commitment aborts pairing |
| MLS delivery service | `/v2/mls`, `version: 2` | Client rejects any other response version; server rejects other request versions |
| MLS delivery entry kinds | `commit`, `application`, `proposal` | Server rejects other kinds; a `proposal` revokes its sender |
| Replication message | `version: 2` inside MLS application messages | Receivers skip messages with another version or shape |
| Replication checkpoint | `sync-v2.json`, version 2 | Engine discards an unreadable checkpoint and rebuilds it from MLS state |
| Replica archive | `replica-v1.json`, format 1 | Unchanged by the cutover; replica validation rejects unsupported archives |

The relay's `/healthz` reports `supportedVersions: [1]`, which describes the
WebSocket room and `/v1/mailbox`. `/v2/mls` checks its own version field.

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

Deploy the relay before the clients. The current relay serves all of:

- the `/v1` WebSocket room, which version 2 clients use for pairing;
- `/v2/mls`, which version 2 clients use for delivery;
- `/v1/mailbox`, which no version 2 client calls.

`/v1/mailbox` stays in the server, with its tests, for this rollout. Version 1
clients that are still installed keep syncing through it with each other until
they update, so removing it before every client has updated would break those
groups before their users can pair again. Remove `/v1/mailbox` and its storage
once no supported client release uses version 1. That removal needs no client
change. The mailbox keeps its existing rules: requests that omit `version` are
treated as version 1, and any other explicit value is rejected before
authorization or mutation.

Production consumers must use the same relay origin for pairing and delivery.
`SyncConfiguration.mailboxURL` still selects that origin, and the engine
derives `/v2/mls` from it. The demo's application identifier and Keychain
service create an independent install; it does not migrate another
application's sandbox or credentials.

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
Python keeps the version 1 route domains in `gotsync_server/protocol.py`.
Preserve it through the final brand rename; changing it requires a protocol
version. Invitation URL schemes are outside the cryptographic wire contract.
Each consumer supplies its own scheme through `SyncConfiguration` and registers
it in its app. The engine rejects URLs with another scheme; the demo uses
`accountless-sync`.
