# GotSync relay

This relay carries opaque traffic for GotSync. It serves three endpoints:

- The volatile WebSocket path `/v1` routes opaque binary frames between two
  peers. Current clients use it only for the pairing exchange.
- The MLS delivery service `/v2/mls`, on the HTTP port, keeps KeyPackages and
  an ordered log of MLS commits, proposals, and application messages per
  group. Current clients send all task changes through it. PROTOCOL.md
  describes its requests.
- The version 1 HTTP mailbox `/v1/mailbox` stores encrypted envelopes for
  version 1 clients. No current client calls it. It stays for the server-first
  rollout described in docs/COMPATIBILITY.md.

The relay does not encrypt, decrypt, or inspect application payloads.
WebSocket frames are never persisted or buffered before a peer arrives. The
HTTP stores persist only opaque bytes, random identifiers, cursors, hashes
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

The WebSocket endpoint is `ws://127.0.0.1:8765/v1`. The mailbox endpoint
defaults to `http://127.0.0.1:8767`. For a simulator to reach a relay running
on the same Mac, `127.0.0.1` works with the iOS Simulator. A real device needs
a deployed TLS endpoint. The relay rejects non-loopback live and mailbox binds
by default. `--allow-insecure-non-loopback` exists only for an explicit local
demo and emits a plaintext-exposure warning.

The mailbox SQLite database defaults to `relay-data/mailbox.sqlite3`, uses WAL
journaling, full synchronous durability, connection-level `secure_delete`, and
mode `0600`. Override the location with `--mailbox-database` and retention with
`--mailbox-retention SECONDS`.

## Live WebSocket relay

The server defaults to at most 256 live WebSocket connections and 128 rooms.
Override these hard limits with `--max-connections` and `--max-rooms`. A lone
peer may wait **15 minutes** (900s) for its partner before it receives
`waitingExpired` and is disconnected — aligned with the app invitation TTL;
configure this with `--waiting-room-ttl`. A full relay
returns `relayBusy` and closes the rejected socket without creating a room.

The first client message must be a text frame no larger than 512 bytes:

```json
{"type":"register","version":1,"route":"base64url-32-bytes"}
```

The route is an unpadded, canonical base64url encoding of exactly 32 opaque
bytes. The relay admits two sockets on a route. Both receive
`{"type":"peerReady","version":1}` when the second arrives. The remaining peer
receives `{"type":"peerLeft","version":1}` when its partner leaves. A third
socket receives a `routeFull` error and closes.

After registration, clients may send only binary messages. The relay forwards
them unchanged only while both peers are live. A message sent before the peer
arrives is dropped immediately. WebSocket compression is disabled. Messages
are limited to 512 KiB, and each destination has a forwarding queue capped at
16 frames and 1 MiB.

## Encrypted mailbox

Every mailbox call is a JSON `POST`; route and authorization values never
appear in a URL:

- `/v1/mailbox/put` accepts `route`, `auth`, and `messages`.
- `/v1/mailbox/fetch` accepts `route`, `auth`, `after`, and an optional `limit`.
- `/v1/mailbox/ack` accepts `route`, `auth`, and `cursor`.
- `/v1/mailbox/forget` accepts `route` and `auth`.

`route`, `auth`, message `id`, and `payload` use canonical unpadded base64url.
The first three decode to exactly 32 bytes. Ordinary encrypted task mailboxes
derive their route as:

```text
SHA256(UTF8("com.gotdone.sync/mailbox-route/v1") || auth)
```

Encrypted pairing-control messages instead derive their route as:

```text
SHA256(UTF8("com.gotdone.sync/pairing-control-route/v2") || auth)
```

Provision chunks, readiness, commit, receipt, and abort records use
stage- and direction-separated authorization values within that namespace.
The server accepts exactly the task-mailbox and pairing-control namespaces and
verifies both relationships with constant-time comparisons on every request.
Routes derived from any other label are rejected. An example append is:

```json
{
  "route": "canonical-base64url-32-bytes",
  "auth": "canonical-base64url-32-bytes",
  "messages": [
    {
      "id": "canonical-base64url-32-bytes",
      "payload": "opaque-encrypted-envelope"
    }
  ]
}
```

`put` returns each stable global `cursor` and an `acknowledged` Boolean. The
Boolean is false while that payload is live and true when only its receipt
tombstone remains after recipient ACK. Reusing an ID with identical bytes is
idempotent, including after acknowledgement; reusing it for different bytes
returns `409`. `fetch` returns the oldest unacknowledged messages after the
requested cursor in cursor order. `ack` logically nulls payloads through the
route-scoped cursor so they are no longer served, while retaining ID/hash
receipts until expiry. SQLite WAL pages, snapshots, and backups are outside
that logical-deletion guarantee. `forget` idempotently deletes all payloads and
receipts for the authorized route.

Request bodies and serialized fetch responses are limited to 512 KiB, pages
and append batches to 128 messages, and each opaque payload to 64 KiB. Fetch
pages may therefore contain fewer than the requested message count. Defaults
allow 10,000 receipts and 64 MiB of live payload per route, plus global caps.
All caps have corresponding `--mailbox-max-*` arguments. At most 64 mailbox
connections are handled concurrently by default; configure that bound with
`--mailbox-max-connections`.

Mailbox data expires after 365 days by default. Fetching does not extend
retention. The first unacknowledged message starts one fixed deadline for that
directional queue. Later messages inherit that deadline instead of extending
it, so dependent operations expire together and continuous writes cannot
retain ciphertext indefinitely. Once every live message is acknowledged or
expired, the next queue receives a fresh full retention period. A client reset
should call `forget`; retention is the fallback when it cannot. Expired rows
are unavailable at the deadline and are purged on startup, during mailbox
access, or by the hourly background purge. Configure that interval with
`--mailbox-purge-interval`.

## Admission and rate limits

The relay limits work per client source before it parses a request body or
accepts a registration. A source is one IPv4 address or one IPv6 `/64`
(`--ipv6-source-prefix`). The limits apply to the WebSocket listener and to
every request on the mailbox listener, including `/v2/mls/*`.

| Limit | Default | Argument | Rejection |
| --- | --- | --- | --- |
| WebSocket connections | 2/s, burst 30 | `--websocket-connect-rate`, `--websocket-connect-burst` | Handshake `429` with `Retry-After` |
| Concurrent WebSockets | 32 | `--max-websockets-per-source` | `rateLimited` frame, close `1013` |
| Mailbox and MLS requests | 40/s, burst 400 | `--http-request-rate`, `--http-request-burst` | `429` `rateLimited` with `Retry-After` |
| Concurrent mailbox and MLS requests | 16 | `--max-http-requests-per-source` | Connection closed, or `429` behind a trusted proxy |

Set a rate and its burst to `0`, or a concurrency limit to `0`, to disable that
limit. A rejected request touches no room, mailbox, or MLS state and does not
consume a token. The Swift mailbox transport retries a `429` up to twice when
`Retry-After` is at most 10 seconds; the engine treats other `429` responses as
transient and retries on its next cycle.

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
- Alerts on the rejection counters, `relayBusy`, mailbox capacity, and disk
  usage.

## Health and metrics

The metrics listener is restricted to a loopback address and defaults to
`127.0.0.1:8766`.

- `GET /healthz` returns process health.
- `GET /readyz` returns readiness only after a bounded SQLite write-lock and
  commit probe succeeds and the database has capacity for another page. The
  probe leaves its logical row unchanged.
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
monotonic, so their gaps can also reveal rough aggregate mailbox write volume.

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
ports on loopback and persist the encrypted mailbox:

```sh
docker run --rm --name gotsync-server \
  -p 127.0.0.1:8765:8765 -p 127.0.0.1:8767:8767 \
  -v gotsync-mailbox:/data gotsync-server
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

New mailbox requests include `version: 1`. This server interprets an omitted
field as legacy version 1 and rejects unsupported explicit values with HTTP
400 `unsupportedVersion` before storage changes. WebSocket registration and
responses remain versioned. `/healthz` advertises `supportedVersions: [1]`.
See [the protocol compatibility notes](../docs/COMPATIBILITY.md).
