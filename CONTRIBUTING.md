# Contributing

## Prerequisites

- Xcode with Swift 6 and the iOS simulator runtime
- [rustup](https://rustup.rs). `rust-toolchain.toml` pins the compiler; the
  build script adds the Apple targets.
- [uv](https://docs.astral.sh/uv/getting-started/installation/) for the Python
  relay

Scripts keep build output in a per-checkout cache under `~/.cache/gotsync`.
Set `GOTSYNC_CACHE_DIR` to move it.

## Build the Rust library

```sh
scripts/build-mls.sh
```

The script builds the `mls/` crate for five Rust targets and produces
`Artifacts/gotsync_mlsFFI.xcframework` with three slices: iOS device (arm64),
iOS simulator (arm64, x86_64), and macOS (arm64, x86_64). It also regenerates
`Sources/GotSyncMLSBindings/GotSyncMLSBindings.swift`. Commit that file when it
changes; CI fails if the committed bindings differ from the generated ones.

`scripts/build-mls.sh --host-only` builds only the macOS arm64 slice. It is
faster but cannot build for iOS.

`Package.swift` uses the local XCFramework whenever `Artifacts/` contains one.
Otherwise SwiftPM downloads the binary pinned in `Package.swift`. Contributors
who do not change `mls/` can skip the Rust build.

## Test

| Command | Runs |
| --- | --- |
| `cargo test --locked --manifest-path mls/Cargo.toml` | Rust crate tests |
| `scripts/uv.sh pytest server/tests -q` | Relay tests |
| `scripts/test-swift.sh` | Swift unit tests; skips real-relay tests |
| `scripts/test-integration.sh` | All Swift tests against a real relay on loopback |
| `scripts/test-mls.sh` | Rust and relay MLS tests, then MLS Swift tests against the delivery service |
| `scripts/test-mls-ios.sh` | iOS device build and MLS tests on a temporary simulator |
| `scripts/check-release-transport.sh` | Demo app Debug and Release builds and their transport rules |

`scripts/test-swift.sh` and `scripts/test-integration.sh` build the macOS
slice first when `mls/` changed after the last local build, or when no local
build exists and `cargo` is installed.

CI runs these steps in order on every pull request: Rust tests, the
XCFramework build, the bindings and pin check, relay tests, real-relay client
tests, iOS tests, the demo builds, and a remote-consumer build from a clean
clone that downloads the pinned binary.

## Publish a new binary

Any change to `mls/`, `rust-toolchain.toml`, `scripts/build-mls.sh`, or the
generated bindings needs a new binary before it can merge. CI reports the
changed inputs.

1. Push the branch.
2. Run the **Publish MLS binary** workflow on that branch with a new tag, such
   as `mls-ffi-0.1.1`. It builds the XCFramework, creates a GitHub release, and
   prints the pin command in the job summary.
3. Run the printed command on the same commit:

   ```sh
   python3 scripts/package-mls.py --pin mls-ffi-0.1.1 CHECKSUM
   ```

   It updates the URL and checksum in `Package.swift` and records the inputs in
   `mls/release.json`.
4. Commit both files and push.

The release archive contains the XCFramework, the license notices of every
bundled Rust crate in `ThirdParty/`, and `provenance.json` with the source
commit and input hashes.
