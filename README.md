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

Implementation is intentionally narrower than a production sync service:

- the foreground app owns live delivery and polls for offline delivery;
- an edit must reach the mailbox before its source device loses connectivity;
- iOS background time is best effort and there are no push notifications;
- mailbox ciphertext expires after 365 days by default;
- initial provisioning is limited to a 280 KiB replica archive;
- the sample syncs small task titles and completion state;
- an interruption at the final two-device pairing commit boundary can require
  resetting and pairing both devices again;
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

The mailbox defaults to `relay/relay-data/mailbox.sqlite3`. Payloads are
end-to-end encrypted, acknowledged only after device-local persistence, and
removed immediately after acknowledgement. Plain WebSocket/HTTP transport and
the ATS exception are development-only.
The relay defaults to 256 live sockets, 128 volatile rooms, and a two-minute
wait for a lone peer; see [the relay README](relay/README.md) for configurable
limits and control error codes.

## Test

Run the iOS tests from Xcode or XcodeBuildMCP, and the relay suite with:

```sh
cd relay
.venv/bin/python -m pytest tests -q
uv pip check --python .venv/bin/python
```
