# Protocol compatibility

These development notes describe the wire formats accepted by the current
client and server implementations. Wire versions identify contracts between
implementations.

## Supported contracts

| Artifact | Version | Validation and mismatch behavior |
| --- | --- | --- |
| WebSocket path and registration | `/v1`, `version: 1` | Relay rejects unsupported registration and closes the socket |
| Relay control JSON | `version: 1` | Client rejects unsupported control before acting on it |
| Encrypted live sync frame | Header version 1 | Not used by `SyncEngine`; secure session rejects an unsupported frame |
| Live task JSON | `version: 1` | Not used by `SyncEngine`; wire codec checks version before decoding kind or mutation |
| Mailbox HTTP requests and responses | `/v1/mailbox`, `version: 1` | Not used by `SyncEngine`; server returns HTTP 400 `unsupportedVersion`; client rejects response mismatch |
| Stored mailbox envelopes and task plaintext | Format 1, bound by `/v1` and authenticated context | Envelope schema remains frozen for version 1; no new suite is accepted under this route |
| Pairing handshake and completion | Version 2 | Handshake and control-record validators reject incompatible input |
| Invitation URL | Consumer-specific scheme and `pair` host with `v=2` | Parser requires `secret`, `group`, and `fingerprint`; `v=1` fails with `unsupportedVersion` |
| MLS delivery service | `/v2/mls`, `version: 2` | Client rejects any other response version; server rejects other request versions |
| MLS pairing frames | Version 2 over the `/v1` WebSocket room, with commitment and nonce frames | Frames that fail authentication or carry an unknown kind abort pairing; a response that does not open the commitment aborts pairing |
| MLS delivery entry kinds | `commit`, `application`, `proposal` | Server rejects other kinds; a `proposal` revokes its sender |
| Replication message | `version: 2` inside MLS application messages | Receivers skip messages with another version or shape |
| Replication checkpoint | `sync-v2.json`, version 2 | Engine discards an unreadable checkpoint and rebuilds it from MLS state |
| Device credentials | Pair 1, group 2 | Credential store validates or migrates pair records to group records |
| Membership snapshot | Signed version 2 | Legacy version 1 can be decoded for migration; active updates require a valid version 2 signature |
| Replica archive | Format 1 | Replica validation rejects unsupported archives |
| Terminal pairing journal | Format 1 | Store rejects unsupported or damaged journals and fails closed |

Version 2 is a breaking cutover. A device that upgrades clears its version 1
link credentials and pairing artifacts at launch, keeps its task replica, and
must pair again. Version 1 and version 2 devices cannot pair with each other.

The mnemonic phrase encodes an invitation secret, not a version negotiation.
Incompatible pairing implementations fail the versioned handshake. The relay's
`/healthz` reports `supportedVersions: [1]`. Health does not imply that a client
has implemented every application-level format in the table.

## Old clients against this server

Existing version 1 WebSocket clients remain supported. Legacy mailbox clients
that omitted the request `version` are interpreted as version 1 at
`/v1/mailbox`. New clients always send the field. A present value must be the
integer 1: null, booleans, strings, and unknown versions are rejected before
mailbox authorization or mutation. Legacy and new requests share storage and
receive versioned responses.

This is a server-first rollout. Deploy a server that accepts the optional field
before deploying these clients. Servers predating that support reject the new
field; this library does not silently retry an unversioned request. Client-to-
client encrypted formats are unchanged, as checked by baseline fixtures.

Production consumers must use the same relay origin when pairing. The demo's
new application identifier and Keychain service create an independent install;
it does not migrate another application's sandbox or credentials.

## Future changes

Within version 1, preserve required fields, cryptographic domains, canonical
encoding, supported limits, and error meanings. Unknown application message
kinds are rejected, so a new kind needs coordinated client support or a new
protocol version. The server treats ciphertext as opaque and does not negotiate
application formats for clients.

A breaking format or cryptographic change requires a new version and endpoint
namespace. Changing existing protocol bytes can make stored data unreadable
and prevent devices from pairing. Test migrations against the existing fixtures
before changing these contracts.

## Frozen identifiers

The version 1 namespace `com.gotdone.sync` and transcript app identifier
`com.gotdone.relay.poc` are protocol bytes, not package names or application
configuration. Swift centralizes them in `ProtocolDomains.swift`; Python keeps
the route domains in `gotsync_server/protocol.py`. Preserve them through the
final brand rename. Changing them requires a protocol migration. Invitation URL schemes are outside the cryptographic wire contract. Each
consumer supplies its own scheme through `SyncConfiguration` and registers it
in its app. The engine rejects URLs with another scheme. A consumer may retain
its old scheme for its own links; the demo uses `accountless-sync`.
