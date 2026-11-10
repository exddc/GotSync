# Public Swift API

This API is for applications embedding GotSync. The package's current model is
task-scoped. The MLS session, pairing frames, replication messages, and replica
archives are implementation details rather than a supported consumer API.

| Surface | Purpose |
| --- | --- |
| `SyncConfiguration` | Validated relay/mailbox URLs, endpoint policy, storage directory, consumer invitation URL scheme, and group profile. `relayURL` ends in `/v2/pairing` and `mailboxURL` in `/v2/mls` |
| `SyncGroupProfile`, `SyncPayloadSchema`, `SyncGroupProfileError` | The application, payload schema, and member limit every group of an engine carries |
| `SyncEngine` | MLS pairing, replication, local task mutations, and transport lifecycle |
| `SyncState`, `SyncPhase`, `MailboxSyncState` | Immutable snapshots and connection state |
| `LinkedDevice` | A group member as listed in `SyncState.linkedDevices` and passed to `removeDevice(_:)` |
| `SecretStore`, `KeychainStore`, `SecretAccessibility` | Consumer-owned secret persistence and Apple's Keychain implementation |
| `BackgroundMailboxScheduling` | Optional OS scheduling supplied by the consuming application |
| `ReplicatedTask` | Visible tasks |
| `Invitation`, `DeviceRole`, `MnemonicError` | Pairing material, the role of this device in a pairing attempt, and invitation parsing errors |
| `SyncError` and transport/configuration errors | Typed failures; UI maps them to its own presentation |
| `SyncEndpointConfiguration`, `EndpointSecurityPolicy` | Endpoint validation with secure defaults |
| `RelaySocket.probeReachability` | Optional check that the pairing relay accepts WebSocket connections, for a developer settings surface |

## Version 2 changes

Version 2 is a breaking API and protocol release. See
[COMPATIBILITY.md](COMPATIBILITY.md) for the cutover.

`SyncEngine.init(configuration:secretStore:backgroundMailboxScheduler:pairingRetryDelayNanoseconds:)`
replaces the initializer that accepted a `mailboxTransport`. Task changes now
travel as MLS application messages, so the version 1 mailbox transport cannot
be injected.

`Invitation.url(scheme:)` produces `v=2` URLs that carry `secret`, `group`, and
`fingerprint`, and it throws when the invitation has no group ID or
fingerprint. `Invitation.from(phrase:)` returns an invitation with only a
secret. Version 1 invitation URLs fail with `MnemonicError.unsupportedVersion`.

New `SyncError` cases:

- `relinkRequired`: version 1 link credentials were cleared at launch. Local
  tasks are kept.
- `syncHistoryBlocked`: the delivery log holds a commit this device cannot
  verify. `mailboxError` and `errorMessage` carry it, `mailboxRequiresRepair`
  is `true`, and `phase` is `.failed` until the application becomes active
  again and retries.
- `syncHistoryExpired`: the relay deleted entries this device had not yet
  received, because the device was offline longer than the relay's retention
  period. It is reported like `syncHistoryBlocked`: unlink and pair again.
- `syncHistoryConflict`: another device sent an operation whose ID this
  device already holds with different content. It is reported like
  `syncHistoryBlocked`. The engine applies nothing from that inbox read, and
  the conflicting entry stays in the MLS inbox. A
  device erased by an earlier version reused its old operation IDs and causes
  this. Unlink the device that reports it, erase the other device, and link
  them again; tasks created on the other device since its earlier erase are
  lost.
- `removedFromGroup`: another member removed this device. The engine erases
  its MLS state, unlinks, keeps local tasks, and shows this in `errorMessage`.
- `approvalExpired`: the inviter did not approve the safety code within 10
  minutes. Nothing was linked.
- `taskHistoryAtCapacity`: the task history has no room for another device.
  It counts retained origins, including those of removed devices, origins of
  changes saved under `replicaCapacityReached`, plus one slot for each current
  member and this device, up to
  `ReplicaLimits.maxOrigins` (128). Creating, inviting,
  or joining fails before anything is linked. The inviter counts the joiner's
  history and every device another member is adding at the same time, and
  both devices report this error when the merged history would not fit.
  Current members keep syncing.
- `replicaCapacityReached`: linked devices sent valid changes that would
  exceed this device's limit of 1,000 tasks including deleted ones, 10,000
  retained changes, or 128 origins over the history's lifetime. The engine
  saves those changes before it acknowledges the messages that carried them,
  and counts them in
  `unappliedRemoteOperationCount`. It saves at most 10,000. When the next
  message does not fit, that message and every later one stay unacknowledged
  in the delivery inbox; nothing saved is replaced. Saved changes are retried
  after launch and whenever new messages arrive. While any remain,
  `mailboxError` and `errorMessage` carry this case and `phase` is `.failed`,
  but sync keeps running. `mailboxRequiresRepair` stays `false`, because
  pairing again does not free capacity. Unlinking, removal, and
  `eraseLocalData()` discard the saved changes; the group's other members
  still hold them. A full store blocks inbox progress until the device unlinks
  or erases. Local uploads continue while the delivery inbox is full, until a
  commit from another member waits behind the held messages; MLS must process
  that commit before this device can send again. Requests from other members for
  missing changes are saved before their messages are acknowledged and
  answered after catching up, one batch at a time, resuming after a failed
  send or restart. A member that asked this device for the whole history then
  gets the reservations snapshot, once this device knows every pending
  reservation itself and holds no saved changes. While it holds some, that
  member asks another member. If the saved changes or saved requests cannot be read
  at launch, the files are kept, the engine reports `localStorageUnavailable` in `mailboxError` and
  `errorMessage` with `phase` `.failed`, sets `mailboxRequiresRepair` while
  linked, and neither syncs nor pairs. `unlinkAndKeepTasks()` or
  `eraseLocalData()` clears it.

  Before applying anything, the engine compares each received change with
  every retained, saved, and received change that has the same origin and
  sequence, byte for byte. A mismatch stops sync with `syncHistoryConflict` and
  leaves the message unacknowledged.

A device that has just joined cannot invite until its inviter has sent it the
group's pending reservations, usually within one sync cycle. Until then,
`inviteToGroup()` fails with `SyncError.privateSyncUnreachable`. The same
applies to a device that created a group, crashed while adding its first
member, and then could not read its saved reservations: it cannot invite
until that member's history arrives on its next sync. An unlinked device that
already created a group first checks the relay's log, because an earlier
invitation may have added someone without the device learning it. If the
relay cannot be reached, `createPrivateSync()` fails with
`SyncError.privateSyncUnreachable`.

`SyncEngine.linkEndedReason` and `SyncState.linkEndedReason` report why this
device stopped being linked without the user unlinking it: `.removedFromGroup`
or `.relinkRequired`. The value is `nil` otherwise and is cleared when a new
pairing attempt starts or the device unlinks. It is not persisted, so show it
while the engine that detected it is running.

Removed in version 2:

- The version 1 mailbox client (`MailboxTransport`, `HTTPMailboxTransport`,
  `StoredMailboxEnvelope` and the receipt and page types) and
  `MailboxTransportError`.
- The keep-both and finalization members, which had no effect after the MLS
  migration: `resolvePairingReplicaConflictKeepingBoth()`,
  `isPairingFinalizationLocked`, `hasPairingReplicaConflict`,
  `pairingFinalizationState`, `keepBothPreview`, `pairingRecoveryResetRequired`,
  `PairingFinalizationState`, and `KeepBothPreview`.
- `SyncPhase.finalizing` and `lastRoundTripMilliseconds`, which the engine no
  longer produces.
- `SyncError` cases that only the version 1 protocol produced:
  `invalidSyncMessage`, `archiveTooLarge`, `safetyCodeMismatch`,
  `pairingReplicaConflict`, `pairingMergeTooLarge`, `legacyPairingNeedsRelink`,
  `pairingRecoveryHistoryFull`, and `pairingRecoveryJournalDamaged`.
- `RelaySocket.sendEncrypted(_:)`, `openEncrypted(_:)`, and
  `clearSecureSession()`. `RelaySocket` now only carries pairing frames.

Pairing merges the joiner's existing tasks with the group's tasks without
asking first. `leaveGroupAndKeepTasks()` behaves like `unlinkAndKeepTasks()`.

### Devices and removal

`SyncState.linkedDevices` (also `SyncEngine.linkedDevices`) lists the members
of the current group, including this device, and is empty while unpaired.
Each `LinkedDevice` has:

- `deviceID`: the member's install identifier.
- `fingerprint`: the SHA-256 of its MLS signature key, also its `id`.
- `shortFingerprint`: the first four fingerprint bytes as hex, for display.
- `isCurrentDevice`: whether the entry is this device.
- `isRemovalPending`: whether `removeDevice` was called and the removal commit
  has not been accepted yet.

`removeDevice(_:)` and `removeDevice(fingerprint:)` save a removal request and
start a sync cycle. They return `false` while unpaired, for this device, and
for a fingerprint outside the group. Sync cycles commit saved removals until
the device is gone, after restarts and conflicting commits as well. The entry
disappears from `linkedDevices` once the commit is accepted. A group may
shrink to this device alone; it stays paired and can invite again.

Removing a device frees a group slot but not its slot in the task history.
`isTaskHistoryAtCapacity` is `true` when linking one more device would leave
no room for a new origin from that device or a current member. It is separate
from `isGroupAtCapacity`, which counts current members only against
`memberLimit`.

### Group profiles and member limits

`SyncConfiguration` takes a `groupProfile`, `SyncGroupProfile.legacyTaskDemo`
by default. The legacy profile creates groups that earlier builds can pair
with and admits eight devices. A profiled configuration names the application
and member limit:

```swift
let profile = try SyncGroupProfile(
    application: "com.example.tasks",
    schema: .taskReplica,
    memberLimit: SyncGroupProfile.supportedMemberCeiling
)
```

The application is 1 to 64 bytes of lowercase ASCII letters, digits, `.` and
`-`, starting with a letter or digit; otherwise the initializer throws
`SyncGroupProfileError.invalidApplication`. `memberLimit` must be between 2 and
`SyncGroupProfile.supportedMemberCeiling` (10), otherwise it throws
`invalidMemberLimit`. `SyncPayloadSchema.taskReplica`, the task model this
engine replicates, is the only schema consumers can select; it does not
describe any other application data.

`SyncEngine.groupProfile` returns the configured profile, and
`SyncEngine.memberLimit` and `SyncState.memberLimit` its member limit. Read the
limit from there instead of hardcoding a count. `isGroupAtCapacity` compares
`linkedMemberCount` with it. `SyncGroupProfile.legacyMemberLimit` (8) is the
limit of legacy groups. `SyncEngine.maximumGroupSize` is deprecated and still
returns 8.

`SyncError.incompatibleGroupProfile` reports that the other device or the
stored group uses another application, schema, schema version, or member
limit. Pairing fails with it on both devices before a KeyPackage is published
or a safety code is shown. When the stored group's profile differs from the
configuration, sync stops with it in `mailboxError`, `mailboxRequiresRepair`
is `true`, and `inviteToGroup()` fails with it; the MLS state and tasks are
kept. Configure the stored profile again, or unlink. Exhaustive switches over
`SyncError` need a case for it. See [COMPATIBILITY.md](COMPATIBILITY.md#group-profiles-and-ten-members)
for mixed builds, relays, and rollback.

`unlinkAndKeepTasks()` and `eraseLocalData()` leave the group. The engine moves
the MLS state into a departure journal and publishes a proposal removing this
device in the background; another member commits it. Before that, the journal
removes devices this device added that have not sent a message yet, including
one whose Add was still being delivered, because no other member knows they
never joined. The journal is erased
once the relay accepts the proposal. Both calls switch to a new MLS identity
and fingerprint at once, so the same install can be invited again.
`eraseLocalData()` also gives the new empty replica a new operation origin, so
tasks created after the erase converge with the tasks other devices kept.

`SecretStore` gains `write(_:account:accessibility:)`. Its default
implementation calls `write(_:account:)`. `KeychainStore` stores the MLS state
key with `.afterFirstUnlockThisDeviceOnly` so background sync can open the MLS
state while the device is locked. Every other secret keeps
`.whenUnlockedThisDeviceOnly`. The task replica and the checkpoint use
`completeUntilFirstUserAuthentication` file protection and are excluded from
backups, so a locked device can persist received tasks.

## Isolation and lifecycle

`SyncEngine` is isolated to `@MainActor`. It preserves the existing serial
orchestration and performs transport I/O asynchronously. `states()` yields the
current immutable snapshot immediately and buffers the newest snapshot for
slow consumers. Each subscriber has its own stream. Intermediate snapshots
may represent progress through a multi-step state change; application UI should
render the latest state.

Keep one live engine per storage directory and secret-store namespace. Use a
separate directory and Keychain service for each independent replica. The
library does not select a host app's bundle, preferences, default endpoints,
or signing team. Keep a strong reference while syncing, cancel observation
when its owner disappears, and call `await stop()` to cancel and await runtime
work before recreating an engine for the same storage.

An iOS consumer provides its own BGTaskScheduler registration and immediate
background task. Forward suspension through `applicationDidEnterBackground()`,
await `waitForBackgroundWork()` during granted time, and call
`stopBackgroundWork()` on expiration. The library's default scheduler does
nothing; it never promises background execution time.

Secret-store operations are synchronous and must be thread-safe. Failures
prevent the engine from treating an ephemeral identity as durable. A production
store must protect secrets at rest and preserve write/read/delete semantics.
Replica storage applies iOS Data Protection on iOS and private directory/file
permissions on macOS. macOS deployments should use FileVault or another
appropriate encryption-at-rest mechanism.

The Keychain implementation requires a service name; use your own application
namespace. Unit tests use an in-memory implementation. The example tests cover
Keychain-backed identity and storage on the iOS Simulator.

## Preview SPI

Two groups of preview API are imported with `@_spi`. They are for the GotDone
integration and may change. `scripts/check-host-spi-surface.py` checks both
surfaces against a reviewed list.

`@_spi(HostJournalPreview)` exposes the host journal. Size `submit` batches
with `HostJournal.submissionLimits`, a `HostSubmissionLimits` value:

| Field | Value |
| --- | --- |
| `maxPayloadBytes` | 65,536 |
| `envelopeOverheadBytes` | 64 |
| `maxRecordsPerSubmit` | 256 |
| `maxEncodedBytesPerSubmit` | 262,144 |

The values come from the journal itself, not from a copy of these numbers.
`Invitation.phraseWordCount` is the number of words in an invitation phrase
(17), read from the phrase codec.

`@_spi(BlobPreview)` exposes encrypted image transfer for host-journal
engines. `await engine.blobTransfers()` returns the `BlobTransferService`
actor, or nil in other modes. The engine binds the service to the active group
during sync and retires the binding before leave, removal, reset or erase
changes MLS state. A binding is kept across launches while the same member stays
in the same group.

| Call | Purpose |
| --- | --- |
| `seal(_:route:source:expectedContentHash:)` | Seal a private clone of a host file under a fresh key and upload it. The host file is never written or deleted |
| `outgoing()` | Statuses. Only `readyForHandoff(descriptor, digest)` exposes a frozen descriptor |
| `confirmHandoff(_:descriptorDigest:)` | Delete the row after the host stored the descriptor in its record; a different digest is `staleConfirmation` |
| `cancelOutgoing(_:)` | Drop a transfer that was never offered |
| `requestIncoming(_:route:descriptor:)` | Queue a descriptor from an accepted host record |
| `incoming()` | Statuses. `awaitingPublish(file, contentHash, digest)` is verified content the host publishes |
| `confirmPublished(_:descriptorDigest:)` | Delete the verified file after the host published it |
| `cancelIncoming(_:)` | Drop an unverified variant, such as a rejected one |
| `registerAvailable(route:descriptor:)`, `unregisterAvailable(route:objectID:)` | Objects whose content the host holds, re-uploaded when other members want them |
| `release(route:objectIDs:)` | Availability hint to the relay |
| `summary()`, `summary(for:)`, `updates()` | Aggregate or kind-filtered transfer/registry counts; byte totals, `relayUnsupported` and resource flags remain global. A signal follows each change |
| `setHooks(_:)` | `verifiedContentURL(contentHash:)` for re-uploads, `acceptsImage(file:image:)` for the host's own image check, and `acceptsData(file:data:)`, which must admit each received data chunk and refuses by default |
| `sealData(_:route:source:expectedContentHash:)` | Seal one application-data chunk of at most 10 MiB, with no image validation |
| `requestIncomingData(_:route:descriptor:)` | Queue an application-data descriptor |
| `registerAvailableData(route:descriptor:)` | Register a data chunk the host holds, for re-upload |

`BlobTransferService.maximumObjectPlaintextLength` exposes the codec's per-object plaintext limit for both content kinds. Filtered counts describe transfers or registered variants, not distinct logical images.

`BlobTransferID` (16 bytes) is chosen and persisted by the host; repeating a
call with the same ID and parameters is safe, and different parameters are
`transferMismatch`. `BlobDescriptorInfo(descriptor:)` reads an image
descriptor's object ID, content hash, length and image fields for keying host
variants by `(route, objectID)`.

Images and application data are separate content kinds (`BlobContentKind`).
Application data is one chunk of a host record too large for a journal
payload. Its descriptor is version 2, with zero flags, zero dimensions and the
media type `com.gotdone.sync.application-data`. Image descriptors stay version
1 and their bytes are unchanged. The image calls refuse a data descriptor, and
the data calls refuse an image descriptor, with `contentKindMismatch`; so does
reusing a transfer ID for the other kind. `BlobDataDescriptorInfo(descriptor:)`
reads a data descriptor's object ID, content hash, length and digest. Statuses
carry `kind`. Other versions and nonzero flags are `unsupportedDescriptor`, and
an earlier library reports a version 2 descriptor as unsupported. A received
chunk is published only after its manifest, part hashes, authentication and
content hash are verified and `acceptsData` admits it; otherwise the variant is
`rejected(.dataRefused)`. The host splits a large record into ordered chunks,
checks the whole record's length and hash after assembling them, and
acknowledges only after applying it. Every chunk counts against the same
ledger and limits as an image. Library caps are 64 MiB of bytes, 16 outgoing rows, 8
incoming rows holding bytes, 1,024 queued descriptors, 4,000 registered
objects and 512 MiB of free disk; a full cap is `capacity(_:)` and nothing is
evicted. Images must pass the provisional validator: at most 10 MiB, JPEG, PNG,
HEIC, HEIF, GIF, TIFF or WebP, at most 64 frames, 8,192 pixels per side and 40
million pixels per frame. These limits are policy, not a measured memory
ceiling. Files live under `blob-v1/` in the storage directory.

### Snapshot bootstrap

A joining host can install a peer's compact state instead of applying every
record. Register `HostSnapshotHooks` with `engine.registerSnapshotHost(_:)`
before pairing; without hooks, bootstrap keeps full history.

**Joiner:**
- A fresh journal asks its provider for a snapshot of the hooks' `HostSnapshotSchema`.
- `HostJournalState.bootstrap` shows `requested` through `installing`. While it does, delivery is held: `incoming` returns nothing and `markApplied` throws `bootstrapPending`. Capture and `submit` continue.
- The library checks the offer's per-origin anchors against records the joiner received and chain-checked itself, then fetches and verifies the content.
- `install(HostSnapshotInstall)` receives a library-owned file, the provider, the covered `[origin: sequence]` and a recipient-local `appliedThrough`. Merge in one transaction that also saves that application mark and snapshot ID, never replacing local data, unsent outbox rows or drafts, then return `.installed`. A repeated ID must return `.installed` without changes.
- After installation, `journal.coveredThrough(after:)` identifies a following contiguous run already represented by the snapshot. Save that mark in the host store before calling `markApplied`. `markApplied` records exactly the saved mark; it never silently advances past it.
- After the install, `incoming` skips covered records and delivers the tail; `completed` reports that the library released its copy.

**Provider:**
- `export(HostSnapshotCut)` writes state that reflects exactly the remote records applied through `appliedThrough` and every submitted record, read in one transaction at the cut's capture counter.
- Return the markers read, or `.notAtCut`, for example while outbox rows are unsent.

**Refusals and fallback:**
- A refusal (`HostSnapshotRefusal`) keeps the offer and delivers every record. It covers:
  - a schema mismatch;
  - an export over `HostSnapshotLimits.maxBytes` (32 MiB), refused after Add;
  - a mismatched anchor;
  - missing or rejected content;
  - a host refusal;
  - no remaining provider.
- `declineSnapshotBootstrap()` ends a held bootstrap.

**Retention:** every record stays retained and byte-checked. A snapshot changes only delivery, never retention.

## Deferred API refinements

Main-actor isolation preserves the existing serial recovery behavior. MLS
calls run on the `MLSSession` actor, but JSON, local file I/O, and secret-store calls still run on that actor and can
block UI responsiveness for large inputs. Moving those operations to a
dedicated actor needs separate concurrency and performance validation.

The `mailbox*` state members and `BackgroundMailboxScheduling` keep their
version 1 names. They now describe delivery through the `/v2/mls` log.
`mailboxURL` is the `/v2/mls` delivery endpoint itself, and `relayURL` is the
`/v2/pairing` WebSocket. Endpoint validation rejects the old `/v1` and
`/v1/mailbox` paths.

The initial extracted API retains diagnostic error strings and the
`showsSavingNotice`/`showsLinkCompleteCelebration` progress timing from the
existing orchestration. Applications can supply their own presentation, but
full separation of localized copy and celebration timing is deferred.
`mailboxError` provides a typed `SyncError` for protocol-version rejection,
which does not invalidate credentials or require link repair, and for a
blocked delivery log. A later API
revision should expose typed codes consistently for all error surfaces.
