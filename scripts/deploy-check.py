import base64
import http.client
import json
import os
import socket
import ssl
import sys
import threading
import time

from websockets.exceptions import InvalidStatus
from websockets.sync.client import connect

HOST = os.environ["GOTSYNC_RELAY_HOST"]
CA_FILE = "/check/ca.crt"
ALLOWED = "198.51.100.2"
DENIED = "192.0.2.2"
ALLOWED_CLIENT = "198.51.100.10"
IDLE_SECONDS = 65


def context() -> ssl.SSLContext:
    return ssl.create_default_context(cafile=CA_FILE)


def tls_socket(via: str, ssl_context: ssl.SSLContext | None = None) -> ssl.SSLSocket:
    raw = socket.create_connection((via, 443), timeout=10)
    return (ssl_context or context()).wrap_socket(raw, server_hostname=HOST)


def send_request(
    via: str,
    method: str,
    path: str,
    body: bytes = b"",
    headers: dict[str, str] | None = None,
    *,
    tls: bool = True,
    content_length: int | None = None,
) -> tuple[int, http.client.HTTPMessage, bytes]:
    sock = tls_socket(via) if tls else socket.create_connection((via, 80), timeout=10)
    lines = [
        f"{method} {path} HTTP/1.1",
        f"Host: {HOST}",
        "Connection: close",
        f"Content-Length: {len(body) if content_length is None else content_length}",
        "Content-Type: application/json",
    ]
    lines += [f"{name}: {value}" for name, value in (headers or {}).items()]
    sock.sendall(("\r\n".join(lines) + "\r\n\r\n").encode() + body)
    response = http.client.HTTPResponse(sock)
    response.begin()
    data = response.read()
    sock.close()
    return response.status, response.headers, data


def deliver(via: str, headers: dict[str, str] | None = None) -> tuple[int, bytes]:
    status, _, data = send_request(via, "POST", "/v2/mls/fetch", b"{}", headers)
    return status, data


def expect(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"FAIL: {message}")
    print(f"ok: {message}")


def route() -> str:
    return base64.urlsafe_b64encode(os.urandom(32)).rstrip(b"=").decode()


def pairing_socket(via: str):
    raw = socket.create_connection((via, 443), timeout=10)
    return connect(
        f"wss://{HOST}/v2/pairing",
        sock=raw,
        ssl=context(),
        server_hostname=HOST,
        open_timeout=20,
    )


def register(socket_, route_id: str) -> None:
    socket_.send(json.dumps({"type": "register", "version": 2, "route": route_id}))


def expect_pairing(first, second) -> None:
    for peer in (first, second):
        message = json.loads(peer.recv(timeout=10))
        expect(message == {"type": "peerReady", "version": 2}, "both peers receive peerReady")
    first.send(b"opaque frame")
    expect(second.recv(timeout=10) == b"opaque frame", "relay forwards a binary frame")


def idle_pairing(result: list[str]) -> None:
    try:
        route_id = route()
        with pairing_socket(ALLOWED) as waiting:
            register(waiting, route_id)
            time.sleep(IDLE_SECONDS)
            with pairing_socket(DENIED) as joining:
                register(joining, route_id)
                expect_pairing(waiting, joining)
        result.append("ok")
    except BaseException as error:
        result.append(f"{type(error).__name__}: {error}")


def check_open() -> None:
    idle_result: list[str] = []
    idle = threading.Thread(target=idle_pairing, args=(idle_result,), daemon=True)
    idle.start()

    status, headers, data = send_request(ALLOWED, "POST", "/v2/mls/fetch", b"{}")
    document = json.loads(data)
    expect(status == 400 and document.get("version") == 2, "delivery request reaches the relay over backend TLS")
    expect(headers.get("Strict-Transport-Security") == "max-age=31536000", "HSTS header is set")

    with tls_socket(ALLOWED) as sock:
        expect(sock.version() == "TLSv1.3", "TLS 1.3 is negotiated by default")
    tls12 = context()
    tls12.maximum_version = ssl.TLSVersion.TLSv1_2
    with tls_socket(ALLOWED, tls12) as sock:
        expect(sock.version() == "TLSv1.2" and "GCM" in sock.cipher()[0], "TLS 1.2 uses an AEAD suite")
    cbc = context()
    cbc.maximum_version = ssl.TLSVersion.TLSv1_2
    cbc.set_ciphers("ECDHE-ECDSA-AES128-SHA")
    try:
        tls_socket(ALLOWED, cbc).close()
        expect(False, "TLS 1.2 CBC suites are refused")
    except ssl.SSLError:
        expect(True, "TLS 1.2 CBC suites are refused")

    status, headers, _ = send_request(ALLOWED, "POST", "/v2/mls/fetch", b"{}", tls=False)
    expect(status == 404 and "Location" not in headers, "plain HTTP gets 404 without a redirect")
    for method, path in (("GET", "/healthz"), ("GET", "/metrics"), ("POST", "/v2/mls"), ("GET", "/")):
        status, _, _ = send_request(ALLOWED, method, path)
        expect(status == 404, f"{method} {path} is not routed")

    status, _, _ = send_request(ALLOWED, "POST", "/v2/mls/fetch", content_length=1_572_864)
    expect(status == 413, "request bodies over 1 MiB are refused")

    held = []
    for _ in range(16):
        sock = tls_socket(ALLOWED)
        sock.sendall(
            (
                f"POST /v2/mls/fetch HTTP/1.1\r\nHost: {HOST}\r\n"
                "Content-Type: application/json\r\nContent-Length: 64\r\n\r\n{"
            ).encode()
        )
        held.append(sock)
    time.sleep(1)
    status, data = deliver(ALLOWED)
    expect(status == 429 and not data.startswith(b"{"), "Traefik refuses a 17th concurrent delivery request from one source")
    status, _ = deliver(DENIED)
    expect(status == 400, "another source is unaffected by that limit")
    for sock in held:
        sock.close()
    time.sleep(1)
    status, _ = deliver(ALLOWED)
    expect(status == 400, "the source recovers once its requests finish")

    route_id = route()
    with pairing_socket(ALLOWED) as first, pairing_socket(DENIED) as second:
        register(first, route_id)
        register(second, route_id)
        expect_pairing(first, second)

    idle.join()
    expect(idle_result == ["ok"], f"a pairing socket survives {IDLE_SECONDS} s idle: {idle_result}")


def check_admission() -> None:
    status, _ = deliver(ALLOWED)
    expect(status == 400, "the relay admits the client address that Traefik forwards")
    status, data = deliver(DENIED)
    expect(status == 403 and json.loads(data).get("error") == "admissionDenied", "the relay denies another client")
    status, _ = deliver(DENIED, {"X-Forwarded-For": ALLOWED_CLIENT})
    expect(status == 403, "a client-supplied X-Forwarded-For is ignored")
    with pairing_socket(ALLOWED):
        expect(True, "an admitted client opens a pairing socket")
    try:
        pairing_socket(DENIED).close()
        expect(False, "a denied client cannot open a pairing socket")
    except InvalidStatus as error:
        expect(error.response.status_code == 403, "a denied client cannot open a pairing socket")

    proxy_rejections = 0
    for _ in range(40):
        status, _, data = send_request(ALLOWED, "GET", "/v2/pairing")
        proxy_rejections += status == 429 and not data.startswith(b"{")
    expect(proxy_rejections > 0, "Traefik rate-limits rapid pairing handshakes from one source")


if __name__ == "__main__":
    {"open": check_open, "admission": check_admission}[sys.argv[1]]()
