#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/project-env.sh"
cd "$GOTSYNC_REPO_ROOT"

project=gotsync-deploy-test
compose_file=server/deploy/traefik/compose.yaml
blobs_file=server/deploy/traefik/compose.blobs.yaml
traefik_image=traefik:v3.7
setup_image=python:3.12-slim
work="$(mktemp -d)"
export GOTSYNC_RELAY_HOST=relay.example.test
long_host="$(printf 'a%.0s' {1..63}).$(printf 'b%.0s' {1..63}).$(printf 'c%.0s' {1..40}).example.test"
export GOTSYNC_RELAY_IMAGE=gotsync-relay-local

printf '%s\n' "services:" "  relay:" "    volumes:" \
    "      - $work/host/data:/data" "      - $work/host/certs:/certs:ro" > "$work/host-dir.yaml"

compose() {
    docker compose -p "$project" -f "$compose_file" \
        -f server/deploy/traefik/compose.build.yaml -f "$work/host-dir.yaml" "$@"
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
docker run --rm -v "$work:/work" -v "$PWD/server/deploy/traefik/setup-host.sh:/setup-host.sh:ro" \
    -e GOTSYNC_HOST_DIR=/work/host \
    "$setup_image" sh -c '
        mkdir -p /work/proxy/dynamic
        sh /setup-host.sh /work/proxy/dynamic
        mkdir -p /work/proxy/test /work/check
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
            -subj /CN='"$GOTSYNC_RELAY_HOST"' -addext subjectAltName=DNS:'"$GOTSYNC_RELAY_HOST"',DNS:'"$long_host"' \
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
    -v "$PWD/scripts/deploy-check.py:/check/deploy-check.py:ro" -v "$work/check/ca.crt:/check/ca.crt:ro" \
    --entrypoint sleep gotsync-relay-local infinity >/dev/null
docker network connect --ip 192.0.2.10 "$project-b" "$project-client"

check() {
    docker exec -e GOTSYNC_RELAY_HOST "$project-client" python /check/deploy-check.py "$@"
}

routed() {
    docker exec -e GOTSYNC_RELAY_HOST -e BLOB_STATUS="$1" "$project-client" python -c '
import os, ssl, socket, sys
context = ssl.create_default_context(cafile="/check/ca.crt")
host = os.environ["GOTSYNC_RELAY_HOST"]
for path, status in (("/v2/mls/fetch", "400"), ("/v2/mls/blob/unknown", os.environ["BLOB_STATUS"])):
    with context.wrap_socket(socket.create_connection(("198.51.100.2", 443), timeout=5), server_hostname=host) as s:
        s.sendall(f"POST {path} HTTP/1.1\r\nHost: {host}\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{{}}".encode())
        if not s.recv(64).startswith(f"HTTP/1.1 {status}".encode()):
            sys.exit(1)'
}

check_relay_logs() {
    local allowed='^(admission: |pairing relay ready |health and aggregate metrics ready |MLS delivery ready |$)'
    if [ "${1:-}" = blobs ]; then
        allowed='^(admission: |pairing relay ready |health and aggregate metrics ready |MLS delivery ready |encrypted blob parts enabled on 0\.0\.0\.0:8767/v2/mls/blob/$|$)'
    fi
    local relay_log unexpected
    relay_log="$(compose "${@:2}" logs --no-log-prefix relay 2>&1)"
    unexpected="$(printf '%s\n' "$relay_log" | grep -vE "$allowed" || true)"
    if [ -n "$unexpected" ]; then
        echo "FAIL: relay logged more than its startup lines:" && echo "$unexpected"
        exit 1
    fi
    if [ "${1:-}" = blobs ] && ! printf '%s\n' "$relay_log" | grep -q '^encrypted blob parts enabled on '; then
        echo "FAIL: the blob-enabled relay did not log its blob startup line"
        exit 1
    fi
    echo "ok: relay logs only its startup lines"
}

check_rendered_config() {
    GOTSYNC_RELAY_HOST="$long_host" compose config --format json > "$work/default.json"
    GOTSYNC_RELAY_HOST="$long_host" compose -f "$blobs_file" config --format json > "$work/blobs.json"
    python3 -I - "$work/default.json" "$work/blobs.json" <<'PY'
import json, sys
default, blobs = (json.load(open(path))["services"]["relay"] for path in sys.argv[1:])
labels, blob_labels = default["labels"], blobs["labels"]
text = json.dumps(default)
assert "blob" not in text.lower() and "control-tag" not in text and "X-GotSync-Route" not in text, "default config has blob routing"
assert not any(key.endswith(".priority") for key in labels), "default config sets a router priority"
assert not any("BLOB" in key for key in default.get("environment") or {}), "default config sets a blob environment"
print("ok: the rendered default config has no blob router, tag, priority or environment")
control = "traefik.http.routers.gotsync-mls"
rule_priority = len(labels[f"{control}.rule"])
assert rule_priority > 200, f"the long host must make the default control priority exceed 200: {rule_priority}"
assert blob_labels.get(f"{control}.priority") == "100", "the override must set the control router priority to 100"
assert blob_labels.get("traefik.http.routers.gotsync-blob.priority") == "200", "the override must set the blob router priority to 200"
print(f"ok: the override sets control 100 and blob 200 explicitly; the default control priority would be {rule_priority}")
middlewares = labels[f"{control}.middlewares"] + ",gotsync-control-tag@docker"
assert blob_labels[f"{control}.middlewares"] == middlewares, "the override drops a control middleware"
changed = {key for key in labels if blob_labels.get(key) != labels[key]}
assert changed == {f"{control}.middlewares"}, f"the override changes other default labels: {changed}"
assert default["command"] == blobs["command"], "the override changes the relay command"
print("ok: the override keeps every control middleware and the command, and appends the control tag")
PY
}
wait_for "Traefik to route the relay" routed 400

echo "== checks without admission"
check open
check blobs-off
check_rendered_config

echo "== checks with --admission-allow 198.51.100.10/32"
compose config --format json | python3 -I -c '
import json, sys
command = json.load(sys.stdin)["services"]["relay"]["command"]
json.dump({"services": {"relay": {"command": command + ["--admission-allow=198.51.100.10/32"]}}}, sys.stdout)' \
    > "$work/admission.json"
compose -f "$work/admission.json" up -d --wait
wait_for "Traefik to route the restarted relay" routed 400
check admission
check_relay_logs default -f "$work/admission.json"

echo "== opt-in blob routing with $blobs_file and a ${#long_host}-character host"
export GOTSYNC_RELAY_HOST="$long_host"
compose -f "$blobs_file" up -d --wait
wait_for "Traefik to route blobs" routed 404
check blobs-on
check_relay_logs blobs -f "$blobs_file"

echo "== downgrade: blob router kept, GOTSYNC_ENABLE_BLOBS=0"
printf '%s\n' "services:" "  relay:" "    environment:" '      GOTSYNC_ENABLE_BLOBS: "0"' > "$work/downgrade.yaml"
compose -f "$blobs_file" -f "$work/downgrade.yaml" up -d --wait
wait_for "Traefik to route the downgraded relay" routed 400
check blobs-downgraded
check_relay_logs default -f "$blobs_file" -f "$work/downgrade.yaml"

echo "== misroute: blob router below the control router"
printf '%s\n' "services:" "  relay:" "    labels:" "      - traefik.http.routers.gotsync-blob.priority=1" > "$work/misroute.yaml"
compose -f "$blobs_file" -f "$work/misroute.yaml" up -d --wait
wait_for "Traefik to route the misrouted relay" routed 404
check blobs-misrouted

echo "== Traefik logs"
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
