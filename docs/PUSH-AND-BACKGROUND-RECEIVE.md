# Push and background receive

Status: design. Nothing in this document is implemented yet.

## Problem

A linked device receives task changes only while its application is active.
The engine polls the delivery log every two seconds while active and stops the
loop on suspension. A suspended device sees nothing until the user opens the
application again.

Two effects follow:

- A device that mostly reads, such as an iPad on a desk, shows stale tasks
  until someone opens it.
- The relay deletes a log entry only after every current member acknowledges
  it (see [PROTOCOL.md](PROTOCOL.md#delivery-service)). A member that stays
  suspended keeps the log growing toward its 10,000-entry or 16 MiB limit.

## Decision for 2.0

- **Phase 1, background app refresh, ships in 2.0.** It needs no wire
  change and adds no third party; the relay gains only an aggregate metric.
  It extends the locked-storage model that 2.0 already has to the install
  identity. It shortens how long a quiet device stays stale and helps the
  relay prune the log.
- **Phase 2, APNs background push, does not ship in 2.0.** It makes Apple a
  third party and stores a durable device identifier on the relay. The 2.0
  positioning says the relay stores only ciphertext. Push works only on the
  publisher's relay. The MLS integration has not had an independent review,
  and push adds a new path that runs MLS processing in the background. iOS
  throttling means push improves average latency without guaranteeing it.
- **Revisit phase 2 after 2.0** once three things exist: the independent
  review, acknowledgement-lag data from the relay metric that phase 1 adds,
  and a threat model and privacy disclosure that name Apple as a third party
  and list the token table among relay data.

## Goals and non-goals

Goals:

- Receive, persist, and acknowledge remote task changes while the application
  is suspended, including on a locked device after first unlock.
- Give the relay and any new party no task content, group key, or MLS
  ciphertext beyond what the relay already holds.
- Keep the relay self-hostable without Apple credentials.

Non-goals:

- User-visible notifications about remote changes.
- Background delivery within a guaranteed latency. iOS decides when a
  suspended application runs.
- Decrypting MLS messages in an app extension.

## Current behaviour

- `SyncEngine.applicationDidEnterBackground()` cancels the poll loop and
  starts one background flush.
- `SyncEngine.performBackgroundMailboxFlushWork()` returns at once when no
  local operation is waiting to upload. When it does run, each sync cycle
  calls `MLSSession.synchronize()`, which fetches and processes the log. A
  device with something to send therefore receives as a side effect. A device
  with nothing to send never runs in the background.
- The demo's `SystemBackgroundMailboxScheduler` submits a `BGProcessingTask`
  only while uploads are pending. The demo `Info.plist` declares the `fetch`
  background mode, but no `BGAppRefreshTask` is registered.
- Locked processing works only in a process that started while the device
  was unlocked. The MLS state key uses `AfterFirstUnlockThisDeviceOnly`, and
  the MLS database, checkpoint, and replica use
  `completeUntilFirstUserAuthentication`
  ([THREAT-MODEL.md](THREAT-MODEL.md#assets-and-trust-boundaries)). The
  install device ID, however, is written by `InstallIdentity.loadOrCreate()`
  with the default `WhenUnlockedThisDeviceOnly`, and `SyncEngine.init` reads
  it first. When iOS launches the process into the background on a locked
  device, that read fails and the engine enters the fatal local error state.
  `hasDurableIdentity` is a constant, so the state lasts until the process
  ends, even if the user unlocks and opens the application.

## Options

| Option | Wake source | New party | Relay change | Verdict |
| --- | --- | --- | --- | --- |
| A. Background app refresh | iOS schedule | None | Aggregate metric only | Phase 1 |
| B. APNs background push | Relay, on append | Apple | Token table and APNs client | Phase 2, deferred |
| C. APNs alert push with a Notification Service Extension | Relay, on append | Apple | Same as B | Reject |
| D. Persistent socket or PushKit | Relay | Apple for PushKit | Socket service | Reject |
| E. Third-party push service | Vendor | Vendor and Apple | Vendor SDK | Reject |

Option A gives the application about 30 seconds at times that iOS picks from
usage patterns, battery, and network, typically tens of minutes to several
hours apart. It does not run after the user force-quits the application, when
Background App Refresh is off, or when Low Power Mode is on.

Option B wakes a device for about 30 seconds per push. Apple treats these
pushes as low priority, throttles them, and advises sending no more than two
or three per hour. iOS does not deliver them after force-quit.

Reasons for rejection:

- **C.** The extension runs in a separate process with a small memory limit.
  To decrypt, it would need the MLS state in a shared app group container. Two
  processes that both advance the MLS ratchet and the delivery cursor can
  corrupt that state, and this design needs no visible notifications.
- **D.** iOS closes sockets of suspended applications. PushKit is reserved for
  VoIP calls; iOS 13 and later terminate an application that receives a VoIP
  push without reporting a call.
- **E.** Firebase Cloud Messaging and similar services deliver through APNs on
  iOS. They add a second third party and an SDK without removing Apple.

## Phase 1: background app refresh

### Locked cold launch

A refresh usually starts a new process, often while the device is locked.
Phase 1 therefore needs these changes before background receive can work:

1. Write the install identity with `AfterFirstUnlockThisDeviceOnly`.
   `InstallIdentity.loadOrCreate()` passes that class on create, and on every
   read made while unlocked it rewrites an item still stored under
   `WhenUnlockedThisDeviceOnly`. `KeychainStore.write` already updates the
   accessibility of an existing item. An install that has not launched
   unlocked since upgrading keeps the old class, and its refreshes fail until
   it does.
2. Audit every other Keychain read on the `SyncEngine.init` path. The MLS
   state key already uses the after-first-unlock class. The legacy version 1
   credential check reads only items that are erased on the first upgraded
   launch.
3. Before the first unlock after boot, every protected item is unavailable.
   Distinguish that case (`errSecInteractionNotAllowed`, or
   `UIApplication.isProtectedDataAvailable` being false) from real storage
   failure: the engine reports a temporary `locked` condition instead of the
   fatal state, retries opening storage on
   `protectedDataDidBecomeAvailableNotification` and on
   `applicationDidBecomeActive()`, and still calls `scheduleRefresh()` so that
   the next refresh is not lost.
4. Test on a device after normal process termination, locked, and unlocked
   once since boot: a refresh restores the same identity and session,
   persists and acknowledges remote changes, and submits the next refresh.

The install device ID is a 128-bit replica identifier, not key material. With
item 1, code running on a locked device after first unlock can read it, as it
can already read the MLS state key and the replica.

### Engine

1. Add `SyncEngine.performBackgroundReceive() async -> BackgroundReceiveResult`
   with cases `newData` (entries were processed), `noData` (the log had
   nothing new), and `failed` (a cycle failed or the task was cancelled).
2. It returns `noData` at once unless five guards hold: linked (`isPaired`),
   durable storage, an open session, no pairing in progress, and no blocked
   history. `performBackgroundMailboxFlushWork()` checks the first three and
   `applicationDidEnterBackground()` the last two. It also returns `noData`
   when the group has one member, since nothing can arrive.
3. It runs sync cycles with `allowInactive: true` until
   `MLSSession.synchronize()` processes no entries. Each cycle also uploads
   pending local operations.
4. It requests cycles through `requestSyncCycle(force:allowInactive:)` and
   awaits `syncCycleTask`, as the flush does today. That method already runs
   at most one cycle at a time: a request during a running cycle queues one
   more cycle instead of starting a second. A flush, a receive, and the
   foreground loop therefore never process the log concurrently. If the
   application becomes active during a receive, the running cycle finishes,
   the receive returns, and the foreground loop continues from the persisted
   cursor.
5. The persistence order stays: the replica is written before the MLS inbox is
   acknowledged. A run cancelled by expiration replays idempotently on the
   next run, as after a crash.

### Scheduling API

Add two requirements to `BackgroundMailboxScheduling` without default
implementations, so that a scheduler that compiles also implements refresh.
2.0 is already a breaking API release, and the repository's two conformers,
`NoopBackgroundMailboxScheduler` and the demo scheduler, gain the methods.
docs/API.md lists the new requirements.

```swift
func registerRefresh(handler: @escaping @MainActor () async -> BackgroundReceiveResult)
func scheduleRefresh()
```

The engine registers its receive handler at launch, next to the existing flush
handler. The engine is the only caller of `scheduleRefresh()`. It calls it
from `applicationDidEnterBackground()` and at the end of each background
receive, under the guards in step 2. When a guard fails, it submits nothing,
and iOS drops any earlier request after running it once.

### Demo

1. Register a `BGAppRefreshTask` with the identifier
   `org.gotsync.example.accountless.refresh` and add it to
   `BGTaskSchedulerPermittedIdentifiers`.
2. `scheduleRefresh()` submits a `BGAppRefreshTaskRequest` with
   `earliestBeginDate` 15 minutes ahead.
3. The task handler awaits the engine handler and calls
   `setTaskCompleted(success:)` with `false` for `failed` and `true`
   otherwise. The expiration handler calls `SyncEngine.stopBackgroundWork()`,
   which cancels the running sync cycle, and completes the task with
   `false`.

### Relay

Add one aggregate metric for acknowledgement lag: the time from an append
until the last current member acknowledges it.

1. Add a nullable `appended_at` column to `mls_entries` through
   `ALTER TABLE`, set on each accepted append. Entries from before the
   migration keep `NULL` and are not sampled.
2. When `_prune` deletes entries, it reads `appended_at` for each deleted row
   and adds `now - appended_at` to one of six counters: up to 1 minute, 15
   minutes, 1 hour, 6 hours, 24 hours, and longer.
3. The counters are integers like the existing metrics. They reset on restart
   and on `POST /metrics/reset`; the append times survive in the database.

The counters carry no group ID, writer, or address, so the rule that metrics
are aggregate only still holds. Their distribution before and after phase 1
shows how stale quiet devices stay and is the input for the phase 2
decision.

### Documentation

Phase 1 changes no wire format. It adds the `appended_at` column, which
gives the relay operator append times it can already infer from request
timing. These documents must change when phase 1 ships:

- README, "Delivery and security limits": "While the application is active,
  the engine polls that log every two seconds."
- PROTOCOL.md, "Replication": "The engine polls the log every two seconds
  while active."
- THREAT-MODEL.md, "Delivery and loss": "The engine receives while its
  application is active."
- THREAT-MODEL.md, "Assets and trust boundaries", and docs/API.md: the
  install identity moves to `AfterFirstUnlockThisDeviceOnly`.
- server/README.md, metrics paragraph: list the lag counters.
- `ProductSyncPolicy.deliverySummary` in the demo. It may say that other phones
  can update in the background. It must not promise when.

On macOS the engine keeps polling while the process runs, so phase 1 targets
iOS only.

## Phase 2: APNs background push

### Flow

1. The user turns on background updates in settings. The setting is off by
   default.
2. The application calls `registerForRemoteNotifications()` and passes the
   token to `SyncEngine.setPushToken(_:)`. The engine registers the token at
   each launch, because iOS can issue a new one.
3. The engine sends `push/register` to `/v2/mls` with the group ID, its writer
   token as authorization, the APNs token, and the APNs environment
   (`production` or `sandbox`).
4. When the relay accepts an `append`, it marks every other current writer
   that has a token as pending. For each pending token whose `next_push_at`
   has passed, it waits a random 0 to 30 seconds, sends one push, clears the
   mark, and sets `next_push_at` to 60 seconds after the send. A token marked
   during that window gets one push when the window ends.
5. The push carries the payload `{"aps":{"content-available":1}}` and the
   headers `apns-push-type: background`, `apns-priority: 5`, and a constant
   `apns-collapse-id`. It carries no group ID, cursor, or entry kind.
6. On wake, the application calls `performBackgroundReceive()` and passes
   the matching `UIBackgroundFetchResult` case to the fetch completion
   handler.
7. The engine sends `push/unregister` when the user turns the setting off and
   before it leaves the group. The relay deletes a token when it revokes the
   writer (Remove commit or leave proposal), when the group expires, and when
   APNs answers `410 Unregistered` or `400 BadDeviceToken`.

The application needs the `aps-environment` entitlement and the
`remote-notification` background mode.

### What the relay stores

One new table keyed by `route` (group ID) and `digest` (writer-token hash),
both already stored. Rows last until unregister, writer revocation, group
expiry, or an APNs rejection.

| Column | Content |
| --- | --- |
| `token` | APNs device token, in plaintext because APNs requires it |
| `environment` | `production` or `sandbox` |
| `updated_at` | Time of the last registration |
| `pending` | Whether an append arrived since the last push |
| `next_push_at` | Earliest time of the next push |

The relay process also needs the APNs provider credentials: a `.p8` signing
key, its key ID, the Apple Developer team ID, and the application's bundle ID
as the push topic. The signing key is a deployment secret. Anyone who holds it
and a token can send pushes to that device.

### What APNs reveals

For each opted-in device, Apple learns:

- when the relay pushes, which approximates when other members edit;
- which devices share a group, because the relay pushes to all members of a
  group within the same minute. Apple can likely link a token to the device's
  Apple ID, so this co-membership may identify the people who share a list.

Apple does not learn task content, the group ID, MLS ciphertext, or member
count beyond the devices it pushes to. Apple's handling of push logs follows
Apple's privacy policy and legal process, which this project does not control.

The relay operator learns something new as well. A token stays the same
across leave and re-pair until the application is reinstalled or restored, so
the relay can link a device's old and new groups even when its IP address
changes. Without push, the relay can link groups only by IP address, timing,
and size.

The random delay in step 4 blurs co-membership timing but does not remove it,
because pushes still cluster within one window. The opt-in setting limits the
exposure to users who choose it.

### Self-hosting

APNs accepts pushes for a bundle ID only when they are signed with a key from
the Apple Developer team that owns it. Only the publisher's relay can push to
the published application. A self-hosted relay cannot, unless its operator
builds and signs the application under their own team.

Push is therefore an optional relay capability. `/healthz` reports
`push: true` when the relay has APNs credentials. Clients register a token
only on a relay that advertises it, and fall back to phase 1 otherwise. The
relay holds one set of credentials and one topic; serving several applications
would need a topic per registration and credentials per team. A
publisher-run push gateway that self-hosted relays could call is possible
later, but the gateway would then learn tokens and timing for every
deployment.

### Threat-model changes

- A member can trigger pushes to other members by appending entries. The
  window in step 4 caps this at one push per minute per device, and iOS
  throttles further. The cost is battery and throttle budget, not data.
- The relay cannot check that a token belongs to the registering device. A
  member who learns another user's token for the same application can register
  it and make the relay wake that device on every append, within the same cap.
  This is accepted: tokens are not shown to users or other members, and the
  cost is battery.
- A malicious relay can send, delay, or withhold pushes. This is denial of
  service, which the relay can already cause by withholding the log.
- Registration requires a current writer token, so a non-member cannot attach
  a token to a group.

### Protocol changes

`push/register` and `push/unregister` are new `/v2/mls` operations that use
the existing request rules. The change is additive within version 2: a client
calls them only when `/healthz` reports `push: true`, and an older relay never
reports it. [COMPATIBILITY.md](COMPATIBILITY.md) gains a row for each operation
when phase 2 ships.

## Open question

Should `performBackgroundReceive()` stop after a fixed number of entries? The
session fetches 8 entries per request (the relay allows up to 32), and each
entry needs an MLS decrypt and a replica write. A backlog of thousands of
entries cannot finish in one 30-second window with or without a cap.
Expiration is already safe because of the persistence order. A cap would only
end the run cleanly, with a `newData` result, before iOS expires it. The default
is no cap.
