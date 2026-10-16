# Consumer API

Create `SyncConfiguration` with consumer-owned relay/mailbox URLs, storage
location, invitation scheme and endpoint security policy. The legacy URL
shapes `/v1` and `/v1/mailbox` remain configuration inputs; the MLS driver uses
`/v3/mls` on the mailbox origin. It does not use legacy encrypted transport.

Provide a `SecretStore` backed by the consumer's Keychain service. `SyncEngine`
publishes `SyncState` through `states()`, owns `TaskReplica`, and performs MLS
transactions in `WireMLS`. Use one engine per storage directory. Restoring or
concurrently opening copied MLS stores is unsupported.

`createPrivateSync()` and `inviteToGroup()` show an invitation QR.
`joinPrivateSync(url:)` accepts a host invitation or a role-specific response.
The response must be scanned on the inviting device. `approveSafetyCode()` is
a legacy presentation compatibility method and does not authorize admission.
A manual short-code approval cannot bypass either scan.

`addTask`, `toggleTask` and `deleteTasks` persist local changes before upload.
When both phones contain tasks, inspect `keepBothPreview` and call
`resolvePairingReplicaConflictKeepingBoth()` to approve the merge. Receive
continues while the app is active; no push path exists.

`removeDevice(_:)` requests removal by replica device ID. `leaveGroupAndKeepTasks()`
sends an authenticated leave request that another member commits.
`unlinkAndKeepTasks()` deletes local MLS state while preserving tasks;
`eraseLocalData()` deletes local tasks too. Neither can erase another device's
saved plaintext. A phone whose local state was reset must re-pair.

Forward lifecycle changes with `applicationDidBecomeActive()` and
`applicationDidEnterBackground()`. The consumer owns iOS background-task time
and implements `BackgroundMailboxScheduling`. Call `stop()` when disposing of
the engine. Locked-device work may stop under complete file protection.

See [the integration contract and gates](WIRE-CORECRYPTO.md).
