# Got Done relay

This is the deliberately small, volatile relay for the Got Done sync proof of
concept. It routes opaque binary WebSocket messages between two live peers. It
does not encrypt, inspect, persist, replay, or buffer frames before a peer
arrives. While both peers are live, it uses only bounded transient forwarding
queues for opaque application frames.

## Run

Python 3.11 or newer is required.

```sh
cd relay
uv venv .venv
uv pip install --python .venv/bin/python -r requirements.txt pytest
.venv/bin/python run.py
```

The WebSocket endpoint is `ws://127.0.0.1:8765/v1`. For a simulator to reach a
relay running on the same Mac, `127.0.0.1` works with the iOS Simulator. A real
device needs a reachable bind address and production TLS.

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

## Health and metrics

The second listener is restricted to a loopback address and defaults to
`127.0.0.1:8766`.

- `GET /healthz` returns process health.
- `GET /metrics` returns aggregate counters and active gauges.
- `POST /metrics/reset` clears cumulative counters while preserving active
  gauges.

Metrics never contain route tokens, payloads, client addresses, headers, or
device identifiers. The WebSocket library logger is disabled, and the relay
does not create a database or payload log. All rooms disappear as soon as they
become empty or their waiting peer expires, and all metrics reset when the
process restarts.

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

This POC is plain `ws://` for local development. A deployed version needs
`wss://`, certificate validation, rate limits, and carefully scrubbed proxy
access logs.
