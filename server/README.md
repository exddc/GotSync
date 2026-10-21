# GotSync relay

This relay carries opaque traffic for GotSync. It serves two endpoints, both
under protocol version 2:

- The volatile WebSocket path `/v2/pairing` routes opaque binary frames
  between two peers. Clients use it only for the pairing exchange.
- The MLS delivery service `/v2/mls`, on the HTTP delivery port, keeps
  KeyPackages and an ordered log of MLS commits, proposals, and application
  messages per group. Clients send all task changes through it.
  [PROTOCOL.md](../docs/PROTOCOL.md) describes its requests.

The relay does not encrypt, decrypt, or inspect application payloads.
WebSocket frames are never persisted or buffered before a peer arrives. The
delivery store persists only opaque MLS messages, KeyPackages, cursors, hashes
needed for authorization and idempotency, and expiry timestamps.

## Run

Python 3.11 or newer and [uv](https://docs.astral.sh/uv/getting-started/installation/)
are required. Run these commands from the repository root.

```sh
scripts/uv.sh gotsync-server
```

The wrapper runs the project with `--locked` and installs its dependencies
from `uv.lock`. It places the Python environment in an external cache unique
to this checkout, disables local bytecode files, and needs no activation.
`pyproject.toml` declares the runtime dependencies, uv build backend, and `dev`
test dependencies. Use `uv lock --project server` after changing dependencies.

The pairing endpoint is `ws://127.0.0.1:8765/v2/pairing`. The delivery
endpoint is `http://127.0.0.1:8767/v2/mls`. For a simulator to reach a relay
running on the same Mac, `127.0.0.1` works with the iOS Simulator. A real
device needs a deployed TLS endpoint. The relay rejects non-loopback pairing
and delivery binds by default. `--allow-insecure-non-loopback` exists only for
an explicit local demo and emits a plaintext-exposure warning.

The delivery SQLite database defaults to `relay-data/mls.sqlite3`, uses full
synchronous durability, and is created with mode `0600` in a `0700` directory.
Override the location with `--database`, the listener with `--delivery-host`
and `--delivery-port`, and the concurrent request bound (64 by default) with
`--delivery-max-connections`.

## Live WebSocket relay

The server defaults to at most 256 live WebSocket connections and 128 rooms.
Override these hard limits with `--max-connections` and `--max-rooms`. A lone
peer may wait **15 minutes** (900s) for its partner before it receives
`waitingExpired` and is disconnected — aligned with the app invitation TTL;
configure this with `--waiting-room-ttl`. A full relay
returns `relayBusy` and closes the rejected socket without creating a room.

The first client message must be a text frame no larger than 512 bytes:

```json
{"type":"register","version":2,"route":"base64url-32-bytes"}
```

The route is an unpadded, canonical base64url encoding of exactly 32 opaque
bytes. The relay admits two sockets on a route. Both receive
`{"type":"peerReady","version":2}` when the second arrives. The remaining peer
receives `{"type":"peerLeft","version":2}` when its partner leaves. A third
socket receives a `routeFull` error and closes.

After registration, clients may send only binary messages. The relay forwards
them unchanged only while both peers are live. A message sent before the peer
arrives is dropped immediately. WebSocket compression is disabled. Messages
are limited to 512 KiB, and each destination has a forwarding queue capped at
16 frames and 1 MiB.

## MLS delivery service

Every delivery call is a JSON `POST` under `/v2/mls/`, and every request and
response carries `version: 2`. The listener answers any other path with `404`
before it reads the request body. Requests are limited to 1 MiB.
[PROTOCOL.md](../docs/PROTOCOL.md) lists the operations, authorization rules,
and limits.

## Health and metrics

The metrics listener is restricted to a loopback address and defaults to
`127.0.0.1:8766`.

- `GET /healthz` returns process health.
- `GET /readyz` returns readiness only after a bounded SQLite write-lock probe
  on the delivery store succeeds. The probe changes no data.
- `GET /metrics` returns aggregate counters and active gauges.
- `POST /metrics/reset` clears cumulative counters while preserving active
  gauges.

Metrics never contain route tokens, authorization values, message IDs,
payloads, client addresses, headers, or device identifiers. The WebSocket
library logger is disabled, and the relay creates no payload log. All live
rooms disappear as soon as they become empty or their waiting peer expires,
and all metrics reset when the process restarts.

The relay still observes unavoidable metadata such as IP addresses, request
timing, ciphertext sizes, and acknowledgement timing. Cursors are global and
monotonic, so their gaps can also reveal rough aggregate delivery write volume.

## Test

```sh
scripts/uv.sh pytest server/tests -q
uv lock --project server --check
```

Run the loopback forwarding benchmark with:

```sh
scripts/uv.sh python server/benchmark.py --iterations 1000 --payload-bytes 256
```

Local development uses plain HTTP and `ws://` for loopback development. A deployed
version needs HTTPS and `wss://`, an admission design resistant to anonymous
capacity exhaustion, rate limits, encrypted backups, operational storage
monitoring, and carefully scrubbed proxy access logs.

## Docker

Build using the server directory as the context:

```sh
docker build -t gotsync-server server
```

The command above runs from the repository root. For local use, publish backend
ports on loopback and persist the delivery store:

```sh
docker run --rm --name gotsync-server \
  -p 127.0.0.1:8765:8765 -p 127.0.0.1:8767:8767 \
  -v gotsync-data:/data gotsync-server
```

The image runs as UID 10001. Its health check probes SQLite readiness on the
loopback metrics listener inside the container. Port 8766 is deliberately not
published. The backend listens on container interfaces with the explicit
plaintext override required for container networking. A public deployment
must terminate HTTPS/WSS at a trusted reverse proxy and keep these ports off
the public network. Restrict the volume and encrypt its backups.

## Protocol versions

The relay speaks only protocol version 2. WebSocket registration must carry
`version: 2`, and control messages carry `version: 2`. Delivery requests with
any other version fail with HTTP 400 `invalidRequest`. `/healthz` advertises
`supportedVersions: [2]`. There is no `/v1` endpoint. See
[the protocol compatibility notes](../docs/COMPATIBILITY.md).
