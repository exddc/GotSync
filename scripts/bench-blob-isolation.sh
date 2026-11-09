#!/bin/bash
# Usage: scripts/bench-blob-isolation.sh direct|traefik --window ID --assigned FILE --out DIR [--sensitivity]
set -euo pipefail
source "$(dirname "$0")/project-env.sh"
cd "$GOTSYNC_REPO_ROOT"

mode=${1:?usage: bench-blob-isolation.sh direct|traefik --window ID --assigned FILE --out DIR [--sensitivity]}
shift
window= assigned= out= extra=()
while [ $# -gt 0 ]; do
    case $1 in
        --window) window=$2; shift 2 ;;
        --assigned) assigned=$2; shift 2 ;;
        --out) out=$2; shift 2 ;;
        --sensitivity) extra+=(--sensitivity); shift ;;
        *) echo "unknown argument $1" >&2; exit 64 ;;
    esac
done
[ -n "$window" ] && [ -f "$assigned" ] && [ -n "$out" ] || { echo "--window, --assigned FILE and --out are required" >&2; exit 64; }
bench=scripts/bench-blob-isolation.py
revision="$(git rev-parse HEAD)$(git diff --quiet HEAD -- && echo || echo -dirty)"

if [ "$mode" = direct ]; then
    uv sync --project server --locked --no-editable --reinstall-package gotsync-server --quiet
    exec "$UV_PROJECT_ENVIRONMENT/bin/python" -I "$bench" direct --window "$window" --assigned "$assigned" \
        --out "$out" --revision "$revision" ${extra[@]+"${extra[@]}"}
fi
[ "$mode" = traefik ] || { echo "mode must be direct or traefik" >&2; exit 64; }

preflight="$(python3 -I "$bench" preflight --mode traefik --window "$window" --assigned "$assigned")" || {
    echo "$preflight"
    exit 2
}
slot_end="$(printf '%s' "$preflight" | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["slotEnd"])')"

project="gotsync-blob-bench-$$-$RANDOM"
traefik_image=traefik:v3.7
setup_image=python:3.12-slim
work="$(mktemp -d "${TMPDIR:-/tmp}/gotsync-blob-bench-XXXXXX")"
sampler=
export GOTSYNC_RELAY_HOST=relay.example.test
export GOTSYNC_RELAY_IMAGE=gotsync-relay-local

printf '%s\n' "services:" "  relay:" "    volumes:" \
    "      - $work/host/data:/data" "      - $work/host/certs:/certs:ro" > "$work/host-dir.yaml"

compose() {
    docker compose -p "$project" -f server/deploy/traefik/compose.yaml -f server/deploy/traefik/compose.build.yaml \
        -f server/deploy/traefik/compose.blobs.yaml -f "$work/host-dir.yaml" "$@"
}

cleanup() {
    status=$?
    trap - EXIT INT TERM
    if [ -n "$sampler" ]; then
        kill "$sampler" 2>/dev/null || true
        wait "$sampler" 2>/dev/null || true
    fi
    docker rm -f "$project-traefik" "$project-client" >/dev/null 2>&1 || true
    compose down -v --remove-orphans >/dev/null 2>&1 || true
    docker network rm "$project-a" "$project-b" >/dev/null 2>&1 || true
    docker run --rm --label "gotsync.bench=$project" -v "$work:/work" "$setup_image" sh -c 'rm -rf /work/*' \
        >/dev/null 2>&1 || true
    rm -rf "$work"
    if clean="$(python3 -I "$bench" verify-clean --project "$project")"; then
        echo "ok: no containers, networks or volumes labelled $project remain"
    else
        echo "FAIL: leftovers: $clean"
        status=1
    fi
    if [ -f "$out/$window-report.json" ]; then
        python3 -I "$bench" annotate --report "$out/$window-report.json" --values "{\"cleanup\": $clean}" || status=1
    fi
    exit "$status"
}
trap cleanup EXIT INT TERM

echo "== stack $project"
docker run --rm --label "gotsync.bench=$project" -v "$work:/work" \
    -v "$PWD/server/deploy/traefik/setup-host.sh:/setup-host.sh:ro" -e GOTSYNC_HOST_DIR=/work/host \
    "$setup_image" sh -c '
        mkdir -p /work/proxy/dynamic /work/proxy/test /work/check /work/out
        sh /setup-host.sh /work/proxy/dynamic
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
            -subj /CN='"$GOTSYNC_RELAY_HOST"' -addext subjectAltName=DNS:'"$GOTSYNC_RELAY_HOST"' \
            -keyout /work/proxy/test/tls.key -out /work/proxy/test/tls.crt 2>/dev/null
        cp /work/proxy/test/tls.crt /work/check/ca.crt
        chmod 644 /work/check/ca.crt
        chmod 777 /work/out
        printf "%s\n" "tls:" "  stores:" "    default:" "      defaultCertificate:" \
            "        certFile: /traefik/test/tls.crt" "        keyFile: /traefik/test/tls.key" \
            > /work/proxy/dynamic/test-default-certificate.yaml'
docker network create --label "gotsync.bench=$project" --subnet 198.51.100.0/24 "$project-a" >/dev/null
docker network create --label "gotsync.bench=$project" --subnet 192.0.2.0/24 "$project-b" >/dev/null
docker run -d --label "gotsync.bench=$project" --name "$project-traefik" --network "$project-a" --ip 198.51.100.2 \
    -v /var/run/docker.sock:/var/run/docker.sock:ro -v "$work/proxy:/traefik" \
    "$traefik_image" \
    --ping=true --ping.entrypoint=http --api.dashboard=true --api.insecure=false \
    --entrypoints.http.address=:80 --entrypoints.https.address=:443 \
    --entrypoints.http.http.encodequerysemicolons=true --entryPoints.http.http2.maxConcurrentStreams=250 \
    --entrypoints.https.http.encodequerysemicolons=true --entryPoints.https.http2.maxConcurrentStreams=250 \
    --entrypoints.https.http3 \
    --providers.file.directory=/traefik/dynamic/ --providers.file.watch=true \
    --certificatesresolvers.letsencrypt.acme.httpchallenge=true \
    --certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=http \
    --certificatesresolvers.letsencrypt.acme.storage=/traefik/acme.json \
    --certificatesresolvers.letsencrypt.acme.caserver=https://127.0.0.1:9/directory \
    --providers.docker=true --providers.docker.exposedbydefault=false \
    --providers.docker.constraints="Label(\`com.docker.compose.project\`,\`$project\`)" >/dev/null
docker network connect --ip 192.0.2.2 "$project-b" "$project-traefik"
compose up -d --build --wait --quiet-pull
docker network connect "${project}_default" "$project-traefik"
docker run -d --label "gotsync.bench=$project" --name "$project-client" --network "$project-a" --ip 198.51.100.10 \
    -v "$PWD/$bench:/bench/bench-blob-isolation.py:ro" -v "$work/check/ca.crt:/check/ca.crt:ro" \
    -v "$work/out:/out" --entrypoint sleep gotsync-relay-local infinity >/dev/null

relay="$(compose ps -q relay)"
routed() {
    docker exec "$project-client" python -c '
import ssl, socket, sys
context = ssl.create_default_context(cafile="/check/ca.crt")
with context.wrap_socket(socket.create_connection(("198.51.100.2", 443), timeout=5), server_hostname="relay.example.test") as s:
    s.sendall(b"POST /v2/mls/blob/unknown HTTP/1.1\r\nHost: relay.example.test\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
    sys.exit(0 if s.recv(64).startswith(b"HTTP/1.1 404") else 1)'
}
for ((attempt=0; attempt<60; attempt++)); do
    routed >/dev/null 2>&1 && break
    [ "$attempt" -lt 59 ] || { echo "timed out waiting for the blob router" >&2; exit 1; }
    sleep 1
done

(
    while :; do
        now="$(date +%s)"
        docker stats --no-stream --format \
            "{\"t\":$now,\"Name\":\"{{.Name}}\",\"CPUPerc\":\"{{.CPUPerc}}\",\"MemUsage\":\"{{.MemUsage}}\"}" \
            "$relay" "$project-traefik" >> "$work/out/samples.jsonl" 2>/dev/null || true
        sleep 2
    done
) &
sampler=$!

echo "== runs"
mkdir -p "$out"
status=0
docker exec "$project-client" python -I /bench/bench-blob-isolation.py run --window "$window" \
    --via 198.51.100.2 --host relay.example.test --ca /check/ca.crt --samples /out/samples.jsonl \
    --slot-end "$slot_end" --out /out --revision "$revision" ${extra[@]+"${extra[@]}"} || status=$?
kill "$sampler" && wait "$sampler" 2>/dev/null || true
sampler=

disk="$(docker exec "$relay" sh -c 'du -sk /data/blobs/v1 /data/blobs.sqlite3* /data/mls.sqlite3* 2>/dev/null' \
    | python3 -I -c 'import json, sys; print(json.dumps({line.split()[1]: int(line.split()[0]) * 1024 for line in sys.stdin}))')"
versions="$(printf '{"docker": "%s", "traefik": "%s"}' "$(docker version --format '{{.Server.Version}}')" \
    "$(docker exec "$project-traefik" traefik version | awk '/^Version:/ {print $2}')")"
unexpected="$(docker logs "$relay" 2>&1 | grep -vE '^(admission: |pairing relay ready |health and aggregate metrics ready |MLS delivery ready |encrypted blob parts enabled on |$)' || true)"
cp "$work/out/$window-report.json" "$work/out/samples.jsonl" "$out/"
python3 -I "$bench" annotate --report "$out/$window-report.json" --samples "$out/samples.jsonl" --host-info \
    --values "{\"disk\": $disk, \"versions\": $versions, \"relayLogClean\": $([ -z "$unexpected" ] && echo true || echo false)}"
exit "$status"
