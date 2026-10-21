# Public Swift API

This API is for applications embedding GotSync. The package's current model is
task-scoped. Cryptographic codecs, key derivation, replica archives, and pairing
journals are implementation details rather than a supported consumer API.

| Surface | Purpose |
| --- | --- |
| `SyncConfiguration` | Validated relay/mailbox URLs, endpoint policy, storage directory, and consumer invitation URL scheme. The MLS endpoint `/v2/mls` is derived from the mailbox origin |
| `SyncEngine` | MLS pairing, replication, local task mutations, and transport lifecycle |
| `SyncState`, `SyncPhase`, `MailboxSyncState` | Immutable snapshots and connection state |
| `SecretStore`, `KeychainStore`, `SecretAccessibility` | Consumer-owned secret persistence and Apple's Keychain implementation |
| `BackgroundMailboxScheduling` | Optional OS scheduling supplied by the consuming application |
| `ReplicatedTask`, `KeepBothPreview` | Visible tasks and merge outcome counts |
| `Invitation`, `DeviceRole`, `PairingFinalizationState` | Pairing material and state |
| `MailboxTransport` and its receipt/envelope types | Version 1 mailbox client; `SyncEngine` no longer uses it |
| `SyncError` and transport/configuration errors | Typed failures; UI maps them to its own presentation |
| `SyncEndpointConfiguration`, `EndpointSecurityPolicy` | Endpoint validation with secure defaults |
| `RelaySocket.probeReachability` | Optional connection check for a developer settings surface |

## Version 2 changes

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
- `removedFromGroup`: another member removed this device. The engine unlinks
  and keeps local tasks.

These members remain for source compatibility and have no effect:
`resolvePairingReplicaConflictKeepingBoth()` does nothing,
`isPairingFinalizationLocked` and `hasPairingReplicaConflict` are always
`false`, and `pairingFinalizationState` and `keepBothPreview` are always `nil`.
Pairing merges the joiner's existing tasks with the group's tasks instead of
asking first. `leaveGroupAndKeepTasks()` currently behaves like
`unlinkAndKeepTasks()`.

`unlinkAndKeepTasks()` and `eraseLocalData()` erase this device's MLS state and
its state key. The next pairing uses a new MLS identity and fingerprint.

`SecretStore` gains `write(_:account:accessibility:)`. Its default
implementation calls `write(_:account:)`. `KeychainStore` stores the MLS state
key with `.afterFirstUnlockThisDeviceOnly` so background sync can open the MLS
state while the device is locked. Every other secret keeps
`.whenUnlockedThisDeviceOnly`.

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

## Deferred API refinements

Main-actor isolation preserves the existing serial recovery behavior. Crypto,
JSON, local file I/O, and secret-store calls still run on that actor and can
block UI responsiveness for large inputs. Moving those operations to a
dedicated actor needs separate concurrency and performance validation.

The initial extracted API retains diagnostic error strings and the
`showsSavingNotice`/`showsLinkCompleteCelebration` progress timing from the
existing orchestration. Applications can supply their own presentation, but
full separation of localized copy and celebration timing is deferred.
`mailboxError` provides a typed `SyncError` for protocol-version rejection,
which does not invalidate credentials or require link repair, and for a
blocked delivery log. A later API
revision should expose typed codes consistently for all error surfaces.
