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
needed for authorization and idempotency, and timestamps that drive
[retention](#retention).

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
device needs a deployed TLS endpoint. The relay serves plaintext only on
loopback. To bind pairing or delivery to any other interface, pass a PEM
certificate chain and key with `--tls-cert` and `--tls-key`; both listeners
then serve only `wss://` and `https://`, and drop clients that do not finish
the TLS handshake within 5 seconds.

The delivery SQLite database defaults to `relay-data/mls.sqlite3`, uses full
synchronous durability, and is created with mode `0600` in a `0700` directory.
Override the location with `--database`, the listener with `--delivery-host`
and `--delivery-port`, the concurrent request bound (64 by default) with
`--delivery-max-connections`, and the retention period (90 days by default,
at least 1) with `--retention-days`.

## Retention

The delivery store deletes every record on the schedule below. It applies the
schedule before each request and once an hour while the relay runs.

| Record | Deleted |
| --- | --- |
| Log entry: commit, Welcome, proposal, or application message | When every current member has acknowledged it, or 90 days after the relay accepted it |
| Acknowledgement cursor of a current member | With its group |
| Group, with its writer hashes and cursors | 90 days after the last request from any member, or 24 hours after creation if it never received an entry |
| Writer hash of a removed member | 24 hours after its removal |
| Rejected-append record | 24 hours after the rejection |
| KeyPackage | Its payload on the first fetch; the row when a commit consumes it or 15 minutes after publication |
| Pairing room | When it becomes empty, or 15 minutes after a lone peer arrives; never written to disk |

`--retention-days` changes the 90-day period. A member that falls behind by
more than that period can no longer follow the group: `fetch` returns HTTP 410
`historyExpired`, and the client reports `SyncError.syncHistoryExpired` so the
user pairs the device again. A request for a deleted group returns the same
error.

Opening a database created before this policy adds the missing columns. Its
existing entries and groups count as created at that moment.

SQLite runs with `secure_delete` on, so it overwrites deleted rows with zeros
in the database file. It uses the `DELETE` rollback journal, which it removes
after each transaction. The journal's freed blocks stay on the filesystem
until the filesystem reuses them, so keep the database on an encrypted volume.

Backups are the operator's responsibility. Encrypt them and delete each backup
within the retention period, so that no backup holds a record longer than the
live store would.

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
are limited to 512 KiB and 4,096 fragments; the relay closes a socket that
exceeds either limit with code `1009`. Each destination has a forwarding queue
capped at 16 frames and 1 MiB.

## MLS delivery service

Every delivery call is a JSON `POST` under `/v2/mls/`, and every request and
response carries `version: 2`. The listener answers any other path with `404`
before it reads the request body. Requests are limited to 1 MiB.
[PROTOCOL.md](../docs/PROTOCOL.md) lists the operations, authorization rules,
and limits.

## Encrypted blob parts (optional)

The relay can store encrypted blob parts under `/v2/mls/blob/`. This lane is
off by default. While it is off, the relay creates no blob files, advertises
no `blobs` capability, and answers blob paths like any unknown delivery
operation, with `400 invalidRequest`.

| Setting | Argument | Environment | Default |
| --- | --- | --- | --- |
| Enable the lane | `--enable-blobs` | `GOTSYNC_ENABLE_BLOBS=1` | off |
| Part directory | `--blob-directory` | `GOTSYNC_BLOB_DIRECTORY` | `relay-data/blobs/v1` |
| Metadata database | `--blob-database` | `GOTSYNC_BLOB_DATABASE` | `relay-data/blobs.sqlite3` |
| Require the proxy route tag | `--blob-require-route-header` | `GOTSYNC_BLOB_REQUIRE_ROUTE_HEADER=1` | off |

Only the exact value `1` turns on an environment switch. An empty path
variable selects the default, and an argument overrides its variable. Keep
the part directory and the database on the same persistent volume as the
delivery database.

The relay stores parts that clients have already encrypted. It checks each
part's SHA-256 and the object identifier, and it never decrypts.
[PROTOCOL.md](../docs/PROTOCOL.md#blob-parts) lists the endpoints and errors.

| Limit | Value |
| --- | --- |
| Part | 524,304 bytes |
| Object | 20 parts, 10,486,080 bytes |
| Group | 201,326,592 bytes (192 MiB), 1,200 objects, 8 incomplete objects |
| Writer | 2 incomplete objects, 2 concurrent blob requests |
| Relay | 8 GiB of objects, 8 concurrent blob requests; 1 GiB of the volume is kept free |
| Source | 8 requests/s with burst 32, 4 concurrent requests, separate from the delivery limits |

A complete object is kept for 30 days after it was last begun or downloaded,
measured to the hour. An incomplete object, or one that a client released, is
kept for 24 hours. A `release` therefore does not return quota at once. Only active writers of a
group can read or write its blobs; a removed writer is refused at once, with
no grace period.

With `--blob-require-route-header`, the relay serves a blob request only when
the TCP peer is a `--trusted-proxy` and the request carries
`X-GotSync-Route: blob`. Any other blob request gets `404 notFound`. The
proxy must overwrite this header on every route that reaches the delivery
listener, so a client cannot choose it.

The blob lane shares these resources with MLS delivery: the 64 delivery
connections and their 2-second header phase, TLS, the proxy process, CPU,
disk, and fsync bandwidth. A proxy that buffers bodies holds up to 1 MiB per
request before the relay authenticates it. The limits bound this sharing;
they do not protect against a distributed flood.

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

The TLS tests create a throwaway certificate with the `openssl` command.

```sh
scripts/uv.sh pytest server/tests -q
uv lock --project server --check
```

Run the loopback forwarding benchmark with:

```sh
scripts/uv.sh python server/benchmark.py --iterations 1000 --payload-bytes 256
```

`scripts/bench-blob-isolation.sh direct|traefik` measures MLS delivery latency
with and without blob load, using synthetic clients on loopback or on its own
Docker networks. It runs only inside a window assigned in the JSON file passed
with `--assigned`. It refuses to start while another window is active or while
`xcodebuild`, `xctest`, or another benchmark runs, and it stops nothing outside
its own run. `scripts/bench-guardian.py` runs each mode, from dependency sync
and stack build to teardown. It asks the mode to stop 90 seconds before the
window ends and kills only processes it started that are still running 30
seconds before the end. It then checks that none of its processes, containers,
networks, or volumes remain, and exits 3 if cleanup is incomplete. Every
request, retry, and phase also stops at one run deadline that leaves time for
teardown.

Local development uses plain HTTP and `ws://` on loopback only. A deployed
version needs HTTPS and `wss://`, the perimeter controls in
[Admission and rate limits](#admission-and-rate-limits), encrypted backups,
operational storage monitoring, and carefully scrubbed proxy access logs.

## Docker

Build using the server directory as the context:

```sh
docker build -t gotsync-server server
```

The command above runs from the repository root. The container listens on its
own interfaces, so it requires TLS. Mount a directory holding `tls.crt` and
`tls.key` (readable by UID 10001) at `/certs`, publish the backend ports on
loopback, and persist the delivery store. For local use, a self-signed pair
works:

```sh
mkdir -p certs && openssl req -x509 -newkey ec \
  -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 -subj /CN=localhost \
  -keyout certs/tls.key -out certs/tls.crt && chmod a+r certs/tls.key
docker run --rm --name gotsync-server \
  -p 127.0.0.1:8765:8765 -p 127.0.0.1:8767:8767 \
  -v "$PWD/certs:/certs:ro" -v gotsync-data:/data gotsync-server
```

The image runs as UID 10001. Its health check probes SQLite readiness on the
loopback metrics listener inside the container. Port 8766 is deliberately not
published. A public deployment must use a certificate from a trusted CA, or
terminate HTTPS/WSS at a trusted reverse proxy. A proxy reaches the container
over TLS; a proxy on the same host as a relay bound to loopback may use plain
HTTP. Keep the backend ports off the public network. Inside a container, every
proxied request arrives from the proxy's address, so append `--trusted-proxy`
with the proxy's network to the command. Mount an admission token file
read-only and set `GOTSYNC_ADMISSION_TOKEN_FILE` to its path. Restrict the
volume and encrypt its backups.

## Deploy a public relay

A public relay needs a host name, a TLS proxy in front of the relay, and the
controls in [Perimeter for a public relay](#perimeter-for-a-public-relay). The
proxy terminates HTTPS and WSS with a certificate from a trusted CA and routes
`/v2/pairing` to port 8765 and `/v2/mls/` to port 8767. A proxy in another
container or on another host reaches the relay over TLS; only a proxy on the
same host may use plain HTTP to a relay bound to loopback.

`deploy/traefik` is an example of such a deployment with Docker Compose and
Traefik 3.4 or newer. It works with any Traefik that has a Docker provider and
a file provider that watches a directory, whether you run Traefik yourself or
a hosting platform runs it for you. Traefik verifies the relay's self-signed
certificate against a pinned copy, and the relay publishes no ports.

### Prepare the host

Allow inbound traffic only to these ports, with a firewall that filters in
front of the server, such as your hosting provider's network firewall. Ports
that Docker publishes bypass host firewalls such as UFW.

| Port | Source | Purpose |
| --- | --- | --- |
| 22/tcp | Administrator addresses only | SSH |
| 80/tcp | Any | ACME HTTP-01 challenges |
| 443/tcp, 443/udp | Any | HTTPS and HTTP/3 |

Reach the dashboards of other tools on the server through port 443 or a VPN,
not through their own ports. Allow only key-based SSH logins
(`PasswordAuthentication no`). Provider-side backups and snapshots of the
server copy the relay database, so keep them off unless they are encrypted
with a key you hold.

Run the setup script as root on the server, with the directory that Traefik's
file provider watches:

```sh
curl -fsSLO https://raw.githubusercontent.com/exddc/GotSync/main/server/deploy/traefik/setup-host.sh
sh setup-host.sh /path/to/traefik/dynamic
```

The script creates `/data/gotsync-relay/data` (mode `0700`, UID 10001) and
`/data/gotsync-relay/certs`. It generates a P-256 certificate for the name
`gotsync-relay`, valid for ten years, and writes `gotsync-relay.yaml` to the
Traefik directory. Traefik loads that file without a restart. It holds:

- the `gotsync-relay` servers transport, which pins the certificate and
  answers `504` when the relay does not accept a connection within 3 seconds
  or send response headers within 15 seconds;
- per-source rate and concurrency limits equal to the relay's defaults, and a
  1 MiB request body limit on the delivery route;
- HSTS, and a TLS option that requires TLS 1.2 or newer with AEAD cipher
  suites.

Running the script again keeps the existing certificate. To rotate it, delete
`/data/gotsync-relay/certs/tls.*`, run the script, and restart the relay at
once: Traefik trusts the new certificate as soon as the script finishes, so
requests fail with `500` until the relay restarts. To keep the files
somewhere else, set `GOTSYNC_HOST_DIR` for the script and override both
volumes of `compose.yaml` in a compose override file.

For an encrypted store, mount a LUKS2 volume at `/data/gotsync-relay` before
you run the script. With the key file on the server's root disk, the server
still reboots unattended. That protects the data on volume snapshots and
discarded disks, but not from anyone with root on the running server.

### Run the relay

Use an image from the [relay releases](https://github.com/exddc/GotSync/releases?q=relay-v).
Each release records its source commit, relay input hash and image digest in
`relay-release.json`. Relay versions are independent of protocol version 2
and the `mls-ffi-*` client binary releases.

1. Point the relay's host name at the server with an `A` record. A `CAA`
   record such as `0 issue "letsencrypt.org"` on the same name limits who may
   issue its certificate.
2. Put `GOTSYNC_RELAY_HOST=relay.example.com` in `server/deploy/traefik/.env`,
   or export it. Set `GOTSYNC_RELAY_IMAGE` to the release's full
   `ghcr.io/exddc/gotsync-relay@sha256:...` reference. If your Traefik names its HTTPS entry point or certificate
   resolver something other than `https` and `letsencrypt`, also set
   `TRAEFIK_ENTRYPOINT` and `TRAEFIK_CERT_RESOLVER`.
3. Run `docker compose pull && docker compose up -d --wait` in `server/deploy/traefik`, then connect
   Traefik to the relay's network with
   `docker network connect gotsync-relay_default <traefik-container>`.

A platform that deploys a compose file from a Git repository can use
`server/deploy/traefik/compose.yaml`, with the variables set in the platform.
Pin its Git revision to the release's source commit as well: that fixes the
deployment configuration alongside the image. Disable deployment on Git pushes.
If the platform escapes `$` in labels, turn that off for this
application, or Traefik receives the variable names instead of their values.
Leave the platform's domain setting empty, because the labels already define
both routes, their middlewares, and the certificate resolver.

Add an `AAAA` record only if Traefik sees the addresses of IPv6 clients.
Docker forwards IPv6 connections to a container on an IPv4-only network from
the bridge gateway address, so every IPv6 client would share one rate-limit
source.

The compose file passes `--trusted-proxy` for the private IPv4 ranges. Only
containers on the relay's Docker networks can reach it, and Traefik removes any
`X-Forwarded-For` header a client sends before it appends the client's
address, unless its entry point sets `forwardedHeaders.insecure` or
`forwardedHeaders.trustedIPs`. The container runs with a read-only root
filesystem, no Linux capabilities, `no-new-privileges`, and limits of 512 MB of
memory and 128 processes.

### Opt-in blob routing

`compose.blobs.yaml` turns on the blob lane behind Traefik. It is not part of
the default deployment, and production does not use it:

```sh
docker compose -f compose.yaml -f compose.blobs.yaml up -d --wait
```

The override sets the blob environment variables, with parts under
`/data/blobs/v1` and the database at `/data/blobs.sqlite3`, and requires the
route tag. It adds a `gotsync-blob` router for `/v2/mls/blob/` with
priority 200. That router has its own per-source limits (8 requests/s with
burst 32, 4 concurrent) and 1 MiB body buffering, and it sets
`X-GotSync-Route: blob`. The existing `gotsync-mls` router gets priority 100
and an extra middleware that sets `X-GotSync-Route: control`; its other
middlewares stay. Traefik's default priority is the length of the rule, so
without these explicit values a long host name would let the control router
take blob paths. Neither router writes access logs.

The transport in `setup-host.sh` waits 15 seconds for response headers. The
relay allows a blob request 30 seconds, so a stalled blob request can end
with a Traefik `504`. Such a request may or may not have taken effect.

To roll back, deploy without the override. Stored blobs stay in `/data` until
you delete `/data/blobs/v1` and `/data/blobs.sqlite3*`. A relay started with
the override but with `GOTSYNC_ENABLE_BLOBS` unset keeps the blob router and
answers blob paths with `400 invalidRequest`, without the capability.

### Tagged releases

Run **Release relay** from GitHub Actions on `main` and enter a version such
as `0.1.0`. The workflow requires successful main CI for its source commit,
creates tag `relay-v0.1.0`, and publishes a GitHub release with the Linux
amd64 and arm64 image `ghcr.io/exddc/gotsync-relay:0.1.0`. An existing tag
must point to that same commit. Relay releases do not run on ordinary pushes.
There is no RC channel.

The workflow compares relay input hashes with the last published version.
Runtime modules, dependencies, Docker inputs and deployment files count;
client code, tests and Markdown documentation do not. Unchanged inputs skip
publication, so a client-only update does not consume a relay version. Run
with a new version and `force` enabled to refresh unchanged inputs against
current base images for a security update.

Each release records its source commit, input hash and image digest in
`relay-release.json`. Versions must increase. Re-running a published version
reuses its exact image, even with `force` enabled, and can retry its deployment.
The source tag and successful main CI are checked again. An interrupted draft
with saved metadata also reuses its image; a draft without metadata resumes
publication. Image version and source revision appear in OCI labels and the
loopback-only `/healthz` response, independently of protocol version 2.

### Coolify releases

Keep the existing Compose application, volumes, host name and Traefik labels.
Configure the GitHub environment `relay-stable`, restricted to `main`, with:

| Setting | Type | Value |
| --- | --- | --- |
| `COOLIFY_URL` | Variable | HTTPS Coolify dashboard URL, without `/api/v1` |
| `COOLIFY_APPLICATION_UUID` | Variable | UUID of the relay Compose application |
| `COOLIFY_TOKEN` | Secret | Read, write and deploy token scoped to that application |

Enable the Coolify API. For the first release, disable `deploy`, then make
the `gotsync-relay` container package public in GitHub's package settings, or
configure registry authentication on the deployment server. New GitHub
container packages start private even for a public repository. Re-run
**Release relay** with the same version and `deploy` enabled; it reuses the
published image. Publishing uses the workflow's `GITHUB_TOKEN`.

With `deploy` enabled, the workflow updates `GOTSYNC_RELAY_IMAGE` to the
release's digest, pins the Compose source to its commit, disables automatic
Git deployments and requests a Coolify deployment. Compose waits for container
health before the workflow reports success. With `deploy` disabled, it only
publishes the version. Production stays pinned between explicit releases.

For rollback, set `GOTSYNC_RELAY_IMAGE` and the Git revision in Coolify to a
previous manifest's digest and source commit, then redeploy. Check database
compatibility before downgrading. Rollback does not alter any release or tag.

For local source builds, add `compose.build.yaml` and supply the local image
name:

```sh
GOTSYNC_RELAY_IMAGE=gotsync-relay-local docker compose \
  -f compose.yaml -f compose.build.yaml up -d --build --wait
```

### Logs and backups

Both relay routes set `observability.accesslogs=false`, so a Traefik access
log leaves their requests out. Requests for the relay's host name that match
neither route still appear in it, with client addresses. The relay prints its
four startup lines and nothing per request. Docker keeps container output in
three rotated files of 10 MB.

The database in `/data/gotsync-relay/data` holds the delivery log and the
KeyPackage store. The example keeps no backups. If the database is lost, every
client receives `historyExpired` and pairs again. If you add backups, encrypt
them before they leave the server (restic does this), leave out the
`mls_packages` table, and delete each backup within the retention period.

### Verify

`scripts/test-deploy.sh` builds the image and runs `setup-host.sh` and
`compose.yaml` behind Traefik v3.7, with a test host name and host directory.
It checks routing, backend certificate pinning, TLS versions and cipher
suites, the proxy limits, admission by the forwarded client address, a pairing
socket that stays idle for 65 seconds, and the absence of relay entries in the
logs. CI runs it on every pull request. It does not cover changes that a
platform makes to the compose file before it deploys it.

After a deployment, check the public endpoint:

```sh
host=relay.example.com
# 400 with "version":2 in the body: the request reached the relay over backend TLS
curl -si -X POST "https://$host/v2/mls/fetch" -H 'Content-Type: application/json' -d '{}'
# 404, or a redirect to HTTPS: never a JSON body with "version":2
curl -si "http://$host/v2/mls/fetch"
# Only 80 and 443 open, and 22 only from administrator addresses
nmap -Pn -p- "$host"
```

## Protocol versions

The relay speaks only protocol version 2. WebSocket registration must carry
`version: 2`, and control messages carry `version: 2`. Delivery requests with
any other version fail with HTTP 400 `invalidRequest`. `/healthz` advertises
`supportedVersions: [2]`. There is no `/v1` endpoint. See
[the protocol compatibility notes](../docs/COMPATIBILITY.md).
