# Got Done relay

This is the deliberately small relay for the Got Done sync proof of concept.
It provides two transports:

- A volatile WebSocket path routes opaque binary messages between two live
  peers with low latency.
- A persistent HTTP mailbox stores opaque, end-to-end-encrypted envelopes so a
  device can publish changes while its peer is offline.

The relay does not encrypt, decrypt, or inspect application envelopes. Live
frames are never persisted or buffered before a peer arrives. The mailbox
persists only opaque bytes, random identifiers, cursors, hashes needed for
idempotency, and expiry timestamps.

## Run

Python 3.11 or newer is required.

```sh
cd relay
uv venv .venv
uv pip install --python .venv/bin/python -r requirements.txt pytest
.venv/bin/python run.py
```

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

The POC defaults to at most 256 live WebSocket connections and 128 rooms.
Override these hard limits with `--max-connections` and `--max-rooms`. A lone
peer may wait two minutes for its partner before it receives `waitingExpired`
and is disconnected; configure this with `--waiting-room-ttl`. A full relay
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
cd relay
.venv/bin/python -m pytest tests -q
uv pip check --python .venv/bin/python
```

Run the loopback forwarding benchmark with:

```sh
.venv/bin/python benchmark.py --iterations 1000 --payload-bytes 256
```

This POC uses plain HTTP and `ws://` for loopback development. A deployed
version needs HTTPS and `wss://`, an admission design resistant to anonymous
capacity exhaustion, rate limits, encrypted backups, operational storage
monitoring, and carefully scrubbed proxy access logs.
