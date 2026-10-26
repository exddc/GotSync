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

## Admission and rate limits

The relay limits work per client source before it parses a request body or
accepts a registration. A source is one IPv4 address or one IPv6 `/64`
(`--ipv6-source-prefix`). The limits apply to the WebSocket listener and to
every request on the delivery listener (`/v2/mls/*`).

| Limit | Default | Argument | Rejection |
| --- | --- | --- | --- |
| WebSocket connections | 2/s, burst 30 | `--websocket-connect-rate`, `--websocket-connect-burst` | Handshake `429` with `Retry-After` |
| Concurrent WebSockets | 32 | `--max-websockets-per-source` | `rateLimited` frame, close `1013` |
| Delivery requests | 40/s, burst 400 | `--http-request-rate`, `--http-request-burst` | `429` `rateLimited` with `Retry-After` |
| Concurrent delivery requests | 16 | `--max-http-requests-per-source` | Connection closed, or `429` behind a trusted proxy |

Set a rate and its burst to `0`, or a concurrency limit to `0`, to disable that
limit. A rejected request touches no room or MLS state and does not consume a
token. The engine treats a `429` as transient and retries on its next cycle.

Each rate limiter tracks at most 65,536 sources (`--rate-limit-max-sources`)
and evicts the least recently used source when full. An attacker controlling
more sources than that can reset other sources' buckets, so size this above
the expected number of active clients and rely on the perimeter for
distributed floods. Concurrency state exists only while a request or socket is
open.

### Client addresses behind a proxy

By default the relay uses the TCP peer address and ignores forwarding headers.
Behind a TLS proxy, every client would then share the proxy's address. Pass
`--trusted-proxy CIDR` (repeatable) for each proxy network. For a request from a
trusted peer, the relay reads `X-Forwarded-For` (or `--client-ip-header`) from
right to left and uses the first address that is not itself a trusted proxy. A
missing or malformed header falls back to the proxy address. The proxy must
overwrite or append to this header; it must never pass a client-supplied value
through unmodified. Only trust addresses that clients cannot reach the relay
from directly.

### Private deployments

Deployment admission is off by default. Two mechanisms restrict a private
relay, and every configured mechanism must pass:

- `--admission-allow CIDR` (repeatable) admits only clients whose resolved
  address is in one of the networks, for example a VPN or tailnet range.
  Rejected clients receive `403` `admissionDenied`.
- `--admission-token-file PATH`, or the `GOTSYNC_ADMISSION_TOKEN_FILE`
  environment variable, names a file of tokens, one per line. Blank lines and
  lines starting with `#` are ignored. Each token must be at least 32 printable
  ASCII characters. Requests and WebSocket handshakes must carry a token in
  the `X-GotSync-Admission` header, or they receive `403`.

The GotSync Swift client does not send an admission token. Use the token to
prove that traffic passed through an authenticating front proxy: the proxy
authenticates users (for example with mTLS or an identity-aware proxy), then
sets the header. The proxy must strip any client-supplied
`X-GotSync-Admission` header. Generate a token with `openssl rand -base64 48`,
store the file with mode `0600`, and keep it out of the image and the command
line. The relay stores only SHA-256 digests, compares them in constant time,
and never logs or exports tokens. Metrics count `admission_rejections`,
`rate_limit_rejections`, and `source_concurrency_rejections` without client
identifiers.

### Perimeter for a public relay

These limits bound damage from one source; they do not stop a distributed
flood or a slow-read attack that stays under the per-source limits. A hardened
public relay host also needs:

- A TLS proxy or load balancer that terminates HTTPS/WSS and is the only
  network path to the relay ports, with `--trusted-proxy` set to its address.
- Connection-rate, request-rate, and concurrent-connection limits at that proxy
  or at a DDoS-protection provider, set at or below the relay's limits.
- Header, idle, and request timeouts at the proxy, plus a cap on WebSocket
  lifetime if long-lived sockets are not required.
- A firewall that drops direct traffic to ports 8765 to 8767 from anywhere other
  than the proxy, and keeps the metrics port on loopback.
- Proxy access logs that omit request bodies, the `Authorization` and
  `X-GotSync-Admission` headers, and, where possible, client addresses.
- Alerts on the rejection counters, `relayBusy`, delivery capacity, and disk
  usage.

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
version needs HTTPS and `wss://`, the perimeter controls in
[Admission and rate limits](#admission-and-rate-limits), encrypted backups,
operational storage monitoring, and carefully scrubbed proxy access logs.

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
the public network. Inside a container, every proxied request arrives from the
proxy's address, so append `--trusted-proxy` with the proxy's network to the
command. Mount an admission token file read-only and set
`GOTSYNC_ADMISSION_TOKEN_FILE` to its path. Restrict the volume and encrypt its
backups.

## Protocol versions

The relay speaks only protocol version 2. WebSocket registration must carry
`version: 2`, and control messages carry `version: 2`. Delivery requests with
any other version fail with HTTP 400 `invalidRequest`. `/healthz` advertises
`supportedVersions: [2]`. There is no `/v1` endpoint. See
[the protocol compatibility notes](../docs/COMPATIBILITY.md).
