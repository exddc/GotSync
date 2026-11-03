#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/project-env.sh"
cd "$GOTSYNC_REPO_ROOT"

project=gotsync-deploy-test
compose_file=server/deploy/coolify/compose.yaml
traefik_image=traefik:v3.7
setup_image=python:3.12-slim
work="$(mktemp -d)"
relay_host="$(docker compose -f "$compose_file" config --format json | python3 -I -c '
import json, re, sys
labels = json.load(sys.stdin)["services"]["relay"]["labels"]
print(re.search(r"Host\(`([^`]+)`\)", labels["traefik.http.routers.gotsync-mls.rule"])[1])')"

printf '%s\n' "services:" "  relay:" "    volumes:" \
    "      - $work/host/data:/data" "      - $work/host/certs:/certs:ro" > "$work/host-dir.yaml"

compose() {
    docker compose -p "$project" -f "$compose_file" -f "$work/host-dir.yaml" "$@"
}

cleanup() {
    status=$?
    if [ "$status" -ne 0 ]; then
        echo "--- traefik" && docker logs "$project-traefik" 2>&1 | grep -v middlewareType=Buffer | tail -40 || true
        echo "--- relay" && compose logs relay 2>&1 | tail -40 || true
    fi
    docker rm -f "$project-traefik" "$project-client" >/dev/null 2>&1 || true
    compose down -v --remove-orphans >/dev/null 2>&1 || true
    docker network rm "$project-a" "$project-b" >/dev/null 2>&1 || true
    docker run --rm -v "$work:/work" "$setup_image" sh -c 'rm -rf /work/*' >/dev/null 2>&1 || true
    rm -rf "$work"
    exit "$status"
}
trap cleanup EXIT INT TERM

wait_for() {
    local description=$1
    shift
    for ((attempt=0; attempt<60; attempt++)); do
        if "$@" >/dev/null 2>&1; then return 0; fi
        sleep 1
    done
    echo "timed out waiting for $description" >&2
    return 1
}

echo "== setup-host.sh"
docker run --rm -v "$work:/work" -v "$PWD/server/deploy/coolify/setup-host.sh:/setup-host.sh:ro" \
    -e GOTSYNC_HOST_DIR=/work/host -e TRAEFIK_DYNAMIC_DIR=/work/proxy/dynamic \
    "$setup_image" sh -c '
        sh /setup-host.sh
        mkdir -p /work/proxy/test /work/check
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
            -subj /CN='"$relay_host"' -addext subjectAltName=DNS:'"$relay_host"' \
            -keyout /work/proxy/test/tls.key -out /work/proxy/test/tls.crt 2>/dev/null
        cp /work/proxy/test/tls.crt /work/check/ca.crt
        chmod 644 /work/check/ca.crt
        printf "%s\n" "tls:" "  stores:" "    default:" "      defaultCertificate:" \
            "        certFile: /traefik/test/tls.crt" "        keyFile: /traefik/test/tls.key" \
            > /work/proxy/dynamic/test-default-certificate.yaml'

echo "== networks and Traefik"
docker network create --subnet 198.51.100.0/24 "$project-a" >/dev/null
docker network create --subnet 192.0.2.0/24 "$project-b" >/dev/null
docker run -d --name "$project-traefik" --network "$project-a" --ip 198.51.100.2 \
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
    --accesslog=true --accesslog.filepath=/traefik/access.log --accesslog.format=json >/dev/null
docker network connect --ip 192.0.2.2 "$project-b" "$project-traefik"

echo "== relay"
compose up -d --build --wait --quiet-pull
docker network connect "${project}_default" "$project-traefik"
docker run -d --name "$project-client" --network "$project-a" --ip 198.51.100.10 \
    -e GOTSYNC_RELAY_HOST="$relay_host" \
    -v "$PWD/scripts/deploy-check.py:/check/deploy-check.py:ro" -v "$work/check/ca.crt:/check/ca.crt:ro" \
    --entrypoint sleep "$project-relay" infinity >/dev/null
docker network connect --ip 192.0.2.10 "$project-b" "$project-client"

delivery_reachable() {
    docker exec "$project-client" python -c '
import os, ssl, socket, sys
context = ssl.create_default_context(cafile="/check/ca.crt")
host = os.environ["GOTSYNC_RELAY_HOST"]
with context.wrap_socket(socket.create_connection(("198.51.100.2", 443), timeout=5), server_hostname=host) as s:
    s.sendall(f"POST /v2/mls/fetch HTTP/1.1\r\nHost: {host}\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{{}}".encode())
    sys.exit(0 if s.recv(64).startswith(b"HTTP/1.1 400") else 1)'
}
wait_for "Traefik to route the relay" delivery_reachable

echo "== checks without admission"
docker exec "$project-client" python /check/deploy-check.py open

echo "== checks with --admission-allow 198.51.100.10/32"
compose config --format json | python3 -I -c '
import json, sys
command = json.load(sys.stdin)["services"]["relay"]["command"]
json.dump({"services": {"relay": {"command": command + ["--admission-allow=198.51.100.10/32"]}}}, sys.stdout)' \
    > "$work/admission.json"
compose -f "$work/admission.json" up -d --wait
wait_for "Traefik to route the restarted relay" delivery_reachable
docker exec "$project-client" python /check/deploy-check.py admission

echo "== logs"
relay_log="$(compose logs --no-log-prefix relay 2>&1)"
unexpected="$(printf '%s\n' "$relay_log" | grep -vE '^(admission: |pairing relay ready |health and aggregate metrics ready |MLS delivery ready |$)' || true)"
if [ -n "$unexpected" ]; then
    echo "FAIL: relay logged more than its startup lines:" && echo "$unexpected"
    exit 1
fi
echo "ok: relay logs only its startup lines"
if docker exec "$project-traefik" grep -q '"RouterName":"gotsync' /traefik/access.log; then
    echo "FAIL: Traefik wrote access log entries for the relay routers"
    exit 1
fi
if ! docker exec "$project-traefik" test -s /traefik/access.log; then
    echo "FAIL: Traefik access log is empty, so the check above proved nothing"
    exit 1
fi
echo "ok: Traefik access log has no relay entries while other requests are logged"
errors="$(docker logs "$project-traefik" 2>&1 | perl -pe 's/\e\[[0-9;]*m//g' | grep -E ' (ERR|ERROR|FTL) ' \
    | grep -viE 'acme|middlewareType=Buffer' || true)"
if [ -n "$errors" ]; then
    echo "FAIL: Traefik reported configuration errors:" && echo "$errors"
    exit 1
fi
echo "ok: Traefik reports no configuration errors"
echo "deployment checks passed"
