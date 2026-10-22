# GotSync

GotSync is an accountless, local-first sync engine for Apple platforms. It links
up to eight devices in one MLS group (RFC 9420, through OpenMLS). The relay
stores and forwards only MLS ciphertext. The current replicated model contains
task titles, completion state, and deletions. The engine is under development and does not offer a generic
record schema.

## Repository layout

| Path | Contents |
| --- | --- |
| `Sources/GotSync` | Swift library, pairing, recovery, replication, and transport |
| `Tests/GotSyncTests` | Library tests and real-server integration coverage |
| `server/` | Python relay and local Docker setup |
| `mls/`, `Packages/GotSyncMLS` | OpenMLS bindings and the Swift wrapper the engine uses |
| `scripts/` | Development, build, and test scripts |
| `Examples/AccountlessSync` | SwiftUI iPhone demo with a local package dependency |
| `docs/` | Protocol, compatibility, threat model, security findings, and design notes |

The root `Package.swift` exports one product, `GotSync`. Adding this repository
in Swift Package Manager builds the library without the example or Python
server. It requires Swift 6, iOS 18 or macOS 14. The demo requires iOS 18.6.
`GotSync` depends on the local `Packages/GotSyncMLS` package, whose
XCFramework is built from `mls/` and not checked in.

## Use the library

Run `scripts/build-mls.sh` once to build the OpenMLS XCFramework for macOS and
iOS (requires the Rust toolchain in `rust-toolchain.toml`). Then add this
checkout as a local package dependency in Xcode and select `GotSync`.

Create the engine on the main actor, supply your endpoints and storage
location, and use a separate Keychain service for each application:

```swift
import Foundation
import GotSync

@MainActor
func makeEngine(storageDirectory: URL) throws -> SyncEngine {
    let configuration = try SyncConfiguration(
        relayURL: URL(string: "wss://sync.example.com/v2/pairing")!,
        mailboxURL: URL(string: "https://sync.example.com/v2/mls")!,
        storageDirectory: storageDirectory,
        invitationURLScheme: "example-app-sync"
    )
    return SyncEngine(
        configuration: configuration,
        secretStore: KeychainStore(service: "com.example.app.sync")
    )
}
```

`mailboxURL` is the MLS delivery endpoint and must end in `/v2/mls`.
`relayURL` must end in `/v2/pairing`; the engine opens that WebSocket only
while pairing.

Observe `engine.states()` as an `AsyncStream<SyncState>`. Call
`createPrivateSync()` on the first device, then `joinPrivateSync(url:)` or
`joinPrivateSync(phrase:)` on the joining device. The invitation URL carries the
group ID and the inviter's MLS fingerprint. The 17-word phrase carries only a
secret, and the joiner learns the rest from an offer sealed under that secret.
Both devices then show a safety code derived from both fingerprints and the
group ID. Compare the codes before calling `approveSafetyCode()` on the
inviting device. Approve within 10 minutes; after that the attempt fails with
`SyncError.approvalExpired`. Any linked device can invite another device with
`inviteToGroup()`.

`SyncState.linkedDevices` lists the group's devices. Call
`removeDevice(_:)` with one of them to remove a lost or stolen device; the
request is saved and retried until the removal commit is accepted.
`unlinkAndKeepTasks()` leaves the group: the remaining devices commit the
removal, and this device erases its MLS state once the relay has the leave
request. A removed device reports `SyncError.removedFromGroup` and keeps its
tasks.

This release speaks only protocol version 2 (MLS over `/v2/mls`) and is a breaking
cutover: it contains no version 1 code, so every link created by an earlier
version must be created again. On first launch the engine clears the old link
credentials, keeps local tasks, and reports `SyncError.relinkRequired`. Deploy
the relay before the clients; see [compatibility](docs/COMPATIBILITY.md).

Local mutations use `addTask(title:)`, `toggleTask(_:)`, and `deleteTasks(ids:)`.
Forward application lifecycle events to `applicationDidBecomeActive()` and
`applicationDidEnterBackground()`. An iOS consumer can inject
`BackgroundMailboxScheduling` and grant a background execution window, as the
demo does. Call `await engine.stop()` when disposing of an engine.

Production policy requires secure endpoints in every build configuration.
Local development must explicitly select `.localDevelopment`; the library has
no fallback endpoint, Info.plist lookup, or developer preferences. See
[the public API](docs/API.md) for the supported surface and lifecycle rules.

## Run the demo

```sh
scripts/uv.sh gotsync-server
open Examples/AccountlessSync/AccountlessSync.xcodeproj
```

Install [uv](https://docs.astral.sh/uv/getting-started/installation/) first.
`scripts/uv.sh` installs the locked dependencies automatically. It stores the
Python environment outside the repository in a cache unique to this checkout.
No virtual environment activation is needed.

Run the `AccountlessSync` scheme on iPhone simulators. Choose **Create link** on
one device and **Join link** on another. After pairing, use **Manage sync** to
invite additional devices. Debug demo builds use loopback endpoints on the
Mac. Physical devices require reachable endpoints.

The [server README](server/README.md) covers Docker, ports, persistence, and TLS
proxy requirements. No public hosted service is provisioned by this repository.

## Delivery and security limits

Edits save locally before transmission. Every group, from two to eight
members, sends task changes as MLS application messages through the relay's
ordered delivery log. While the application is active, the engine polls that
log every two seconds. There are no inbound push notifications and no live
socket for task changes. Background upload depends on the execution time the
operating system grants and retries on the next launch. See
[push and background receive](docs/PUSH-AND-BACKGROUND-RECEIVE.md) for the
planned design.

All linked devices share access to the group's tasks. A live invitation is an
admission capability. The safety code protects against accidental pairing and
key substitution, but does not recover the secrecy of a stolen invitation.
There is no account recovery when every device is lost.

If the relay serves a commit that this device cannot verify, sync stops at that
point and the engine reports `SyncError.syncHistoryBlocked`. Local tasks stay
editable; unlink and pair again to keep syncing.

Removing a device stops it from reading later changes, but it keeps the tasks
it already has and cannot be wiped remotely. Any member can remove any other
member; there is no administrator. The MLS integration and the pairing-frame
construction have not received an independent review, so do not describe this
library as audited. Read the [threat model](docs/THREAT-MODEL.md) and
[red-team findings](docs/SECURITY-RED-TEAM.md) before using it with sensitive data.

## Test

```sh
scripts/uv.sh pytest server/tests -q
scripts/test-swift.sh
scripts/test-mls.sh
scripts/test-integration.sh
```

The integration script starts the actual Python relay with a temporary SQLite
database, checks readiness, runs Swift tests, and stops the server on exit. Its
integration test pairs three engines over MLS and verifies delivery while active,
offline catch-up after restart, multi-device convergence, and that a removed
device stops receiving while the others keep converging. `scripts/test-swift.sh`
runs unit tests and explicitly skips that integration test. Swift build files
also stay in the external checkout cache.
