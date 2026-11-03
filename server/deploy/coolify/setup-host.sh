#!/bin/sh
set -eu

host_dir=${GOTSYNC_HOST_DIR:-/data/gotsync-relay}
dynamic_dir=${TRAEFIK_DYNAMIC_DIR:-/data/coolify/proxy/dynamic}
relay_id=10001

install -d -m 755 "$host_dir"
install -d -m 700 -o "$relay_id" -g "$relay_id" "$host_dir/data"
install -d -m 750 -o 0 -g "$relay_id" "$host_dir/certs"

if [ ! -s "$host_dir/certs/tls.crt" ] || [ ! -s "$host_dir/certs/tls.key" ]; then
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -days 3650 -subj /CN=gotsync-relay -addext subjectAltName=DNS:gotsync-relay \
        -keyout "$host_dir/certs/tls.key" -out "$host_dir/certs/tls.crt" 2>/dev/null
fi
chown "0:$relay_id" "$host_dir/certs/tls.crt" "$host_dir/certs/tls.key"
chmod 644 "$host_dir/certs/tls.crt"
chmod 640 "$host_dir/certs/tls.key"

install -d -m 755 "$dynamic_dir"
config="$dynamic_dir/gotsync-relay.yaml"
{
    cat <<'YAML'
http:
  serversTransports:
    gotsync-relay:
      serverName: gotsync-relay
      forwardingTimeouts:
        dialTimeout: 3s
        responseHeaderTimeout: 15s
      rootCAs:
        - |
YAML
    sed 's/^/          /' "$host_dir/certs/tls.crt"
    cat <<'YAML'
  middlewares:
    gotsync-hsts:
      headers:
        stsSeconds: 31536000
    gotsync-mls-rate:
      rateLimit:
        average: 40
        burst: 400
    gotsync-mls-inflight:
      inFlightReq:
        amount: 16
        sourceCriterion:
          ipStrategy:
            depth: 0
    gotsync-mls-body:
      buffering:
        maxRequestBodyBytes: 1048576
    gotsync-pairing-rate:
      rateLimit:
        average: 2
        burst: 30
    gotsync-pairing-inflight:
      inFlightReq:
        amount: 32
        sourceCriterion:
          ipStrategy:
            depth: 0
tls:
  options:
    gotsync:
      minVersion: VersionTLS12
      cipherSuites:
        - TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
        - TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
        - TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
        - TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
        - TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305
        - TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305
YAML
} > "$config.tmp"
chmod 644 "$config.tmp"
mv "$config.tmp" "$config"

echo "relay data: $host_dir/data"
echo "backend certificate: $host_dir/certs/tls.crt"
echo "proxy configuration: $config"
