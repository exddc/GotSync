# Got Done Relay

An experimental, accountless, end-to-end encrypted two-device sync proof of
concept for Got Done.

The project contains:

- a SwiftUI iPhone sample app;
- a reusable local-first replication and encrypted transport layer;
- a Python relay with volatile WebSocket rooms, a durable encrypted mailbox,
  and aggregate metrics;
- unit and two-simulator integration verification;
- protocol, threat-model, latency, and Got Done integration documentation.

## Product delivery contract (open-to-sync POC)

This sample is **open-to-sync**, not set-and-forget:

- Local edits save on the editing iPhone first and never require the peer online.
- Live delivery works while both apps are open.
- Offline mailbox delivery is polled in the foreground; iOS background upload is
  best effort for in-flight puts, with durable retry on the next launch.
- There are **no push notifications**. The other iPhone sees updates while it is
  open, or the next time it opens Got Done.
- Private Sync links **exactly two iPhones**. There is no account recovery for a
  third device yet.
- Invitation QR/phrase TTL is **15 minutes** (single shared constant).

In-app empty states, footers, and sync notices use this contract. Do not claim
that edits appear on a force-quit peer unless a push/background receive path is
added.

Implementation is intentionally narrower than a production sync service:

- the foreground app owns live delivery and polls for offline delivery;
- outbound changes checkpoint to the mailbox; incomplete puts retry after relaunch;
- iOS background time is best effort and there are no push notifications;
- mailbox envelopes expire after 365 days by default;
- initial provisioning is limited to a 280 KiB replica archive;
- the sample syncs small task titles and completion state;
- post-handshake pairing provision, ready, commit, receipt, and cancellation
  are durable and resume after interrupted responses or app restarts;
- a phone with preserved local tasks can join or re-link without overwriting
  them; matching history is reused, additive-only merges continue automatically,
  and true conflicts require confirmation with an outcome preview;
- consumer UI uses outcome language; protocol diagnostics stay under DEBUG;
- the cryptographic protocol is experimental and not independently audited.

Read [the research](docs/RESEARCH.md) and
[the protocol](docs/PROTOCOL.md) before using the code. The
[architecture diagrams](docs/ARCHITECTURE.md) and
[verification report](docs/RESULTS.md) show the implemented flow and observed
results.

## Run locally

The sample targets iOS 18.6 or newer. Start the relay first:

```sh
cd relay
uv venv .venv
uv pip install --python .venv/bin/python -r requirements.txt pytest
.venv/bin/python run.py
```

Open `GotDoneRelay.xcodeproj` and run the `GotDoneRelay` scheme on two iPhone
simulators. On one choose **Create Private Sync**. On the other choose
**Join Existing Sync**, enter the phrase, compare the safety codes, and approve
on the host.

The local development endpoints are:

- WebSocket relay: `ws://127.0.0.1:8765/v1`
- encrypted mailbox: `http://127.0.0.1:8767/v1/mailbox`
- loopback-only health and aggregate metrics: `http://127.0.0.1:8766`

Debug builds fall back to those loopback endpoints. Release builds have no
fallback and fail closed unless the build injects both:

- `GOTDONE_RELAY_URL`, using `wss://` and the exact `/v1` path;
- `GOTDONE_MAILBOX_URL`, using `https://` and the exact `/v1/mailbox` path.

Release validation rejects loopback, plaintext, credentials in URLs, queries,
fragments, and unresolved build-setting placeholders before the sync model
starts. The HTTP and WebSocket transports reject redirects at request time.

The mailbox defaults to `relay/relay-data/mailbox.sqlite3`. Payloads are
end-to-end encrypted, acknowledged only after device-local persistence, and
no longer served after acknowledgement. Plain WebSocket/HTTP transport and the
ATS exception are development-only.
The relay defaults to 256 live sockets, 128 volatile rooms, and a two-minute
wait for a lone peer. Its plaintext listeners are loopback-only unless an
explicit insecure-demo override is supplied. See
[the relay README](relay/README.md) for configurable limits and control error
codes.

## Test

Run the iOS tests from Xcode or XcodeBuildMCP, and the relay suite with:

```sh
cd relay
.venv/bin/python -m pytest tests -q
uv pip check --python .venv/bin/python
```
