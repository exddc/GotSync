# GotSync: Wire CoreCrypto alternative

This TW-531 review branch implements accountless Apple task sync with Wire
CoreCrypto 10.5.4 MLS. `SyncEngine` uses it for pairing, encrypted delivery,
offline catch-up and membership changes. Up to eight devices share one MLS
group. The relay receives no task-content keys.

Switching from the custom protocol or the separate OpenMLS PR requires
re-pairing. Local task replica format 1 remains supported. There are no
accounts, recovery service or push notifications. Losing every device loses
the tasks permanently.

**Adoption gates:** CoreCrypto is GPL-3.0-only; closed-source/distribution
compatibility is unresolved. Physical iPhone and power-loss tests and
external integration security review remain pending. Internal model reviews
are not an independent audit. See [the integration contract](docs/WIRE-CORECRYPTO.md)
and [the red-team record](docs/SECURITY-RED-TEAM.md).

## Build and test

The iOS app is `Examples/AccountlessSync/AccountlessSync.xcodeproj`, scheme
`AccountlessSync`. SwiftPM downloads the checksum-pinned iOS arm64 framework.
Only arm64 simulator binaries are published upstream.

macOS tests require a local source build because the release has no macOS slice:

```sh
scripts/build-wire-host.sh
scripts/test-swift.sh
scripts/test-integration.sh
PYTHONPATH="$PWD/server" scripts/uv.sh pytest server/tests
```

The build script prints the `GOTSYNC_WIRE_HOST` value for direct `swift test`
commands. Set `GOTSYNC_WIRE_BUILD` to reuse a source-build directory. Generated
host bindings and libraries stay outside version control. The upstream source
commit and its Cargo.lock pin Rust dependencies.

Run the relay with `scripts/uv.sh python server/run.py`. The new client uses
HTTPS `POST /v3/mls` on the mailbox listener. Configure the existing endpoint
URLs as described by [the API notes](docs/API.md). Explicit local development
allows loopback HTTP; production requires HTTPS.

## Pairing and removal

The second phone scans the invitation. The first phone then scans the second
phone's response. Local tasks remain on their phone until the user approves
combining lists. A Welcome alone never activates a joiner: the SDK-authenticated
inviter must confirm the actual MLS context.

Removing a member changes the MLS epoch and revokes its write capability.
Leaving sends an authenticated request for another member to commit removal,
so it can wait for a peer to come online. Prior plaintext is not remotely wiped.
All members can read and edit shared tasks. Relay metadata and public MLS
membership information remain visible.

The relay bounds storage and prunes below acknowledged cursors. A long-offline
member can cause backpressure. Empty groups retire on unlink. Public-service rate limiting/admission remains
a deployment requirement.
