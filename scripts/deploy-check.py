import base64
import hashlib
import http.client
import json
import os
import socket
import ssl
import sys
import threading
import time

from gotsync_server.blob_format import PART_BYTES, TAG_BYTES, layout, object_id
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
    content_type: str | None = "application/json",
) -> tuple[int, http.client.HTTPMessage, bytes]:
    sock = tls_socket(via) if tls else socket.create_connection((via, 80), timeout=10)
    lines = [
        f"{method} {path} HTTP/1.1",
        f"Host: {HOST}",
        "Connection: close",
        f"Content-Length: {len(body) if content_length is None else content_length}",
    ]
    if content_type is not None:
        lines.append(f"Content-Type: {content_type}")
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


BLOB_CAPABILITY = {
    "version": 1, "partBytes": 524304, "maxObjectBytes": 10486080, "maxParts": 20,
    "groupQuotaBytes": 201326592, "retentionSeconds": 2592000, "incompleteSeconds": 86400,
}


def b64(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode()


def bearer(token: bytes) -> dict[str, str]:
    return {"Authorization": f"Bearer {b64(token)}"}


def is_json(data: bytes) -> bool:
    try:
        json.loads(data)
    except ValueError:
        return False
    return True


def mls_call(via: str, operation: str, token: bytes, **values) -> tuple[int, dict]:
    body = json.dumps({"version": 2, **values}).encode()
    status, _, data = send_request(via, "POST", f"/v2/mls/{operation}", body, bearer(token))
    return status, json.loads(data)


def blob_call(via: str, operation: str, token: bytes, headers: dict[str, str] | None = None,
              **values) -> tuple[int, http.client.HTTPMessage, bytes]:
    body = json.dumps({"version": 2, **values}).encode()
    return send_request(via, "POST", f"/v2/mls/blob/{operation}", body, {**bearer(token), **(headers or {})})


def blob_part(via: str, operation: str, group: bytes, object_: bytes, index: int, token: bytes, body: bytes = b"",
              headers: dict[str, str] | None = None) -> tuple[int, http.client.HTTPMessage, bytes]:
    return send_request(
        via, "POST", f"/v2/mls/blob/{operation}/{b64(group)}/{b64(object_)}/{index}", body,
        {**bearer(token), **(headers or {})},
        content_type="application/octet-stream" if operation == "put" else None,
    )


def new_group(via: str = ALLOWED) -> tuple[bytes, bytes]:
    group, token = os.urandom(32), os.urandom(32)
    status, _ = mls_call(via, "create", token, group=b64(group))
    expect(status == 200, "a test writer creates an MLS group through Traefik")
    return group, token


def synthetic_object(group: bytes, length: int) -> tuple[bytes, list[bytes], list[bytes]]:
    parts_count, last = layout(length)
    parts = [os.urandom(PART_BYTES) for _ in range(parts_count - 1)] + [os.urandom(last)]
    hashes = [hashlib.sha256(part).digest() for part in parts]
    return object_id(group, length, tuple(hashes)), hashes, parts


def begin(via: str, group: bytes, token: bytes, length: int,
          headers: dict[str, str] | None = None) -> tuple[int, bytes, bytes, list[bytes]]:
    object_, hashes, parts = synthetic_object(group, length)
    status, _, data = blob_call(via, "begin", token, headers, group=b64(group), object=b64(object_),
                                length=length, parts=[b64(value) for value in hashes])
    return status, data, object_, parts


def expect_not_found(status: int, data: bytes, message: str) -> None:
    expect(status == 404 and json.loads(data) == {"error": "notFound", "version": 2}, message)


def check_blobs_off() -> None:
    group, token = new_group()
    status, document = mls_call(ALLOWED, "capabilities", token, group=b64(group))
    expect(status == 200 and document == {"conditionalAppend": True, "version": 2},
           "capabilities advertise no blobs without the opt-in override")
    status, data, _, _ = begin(ALLOWED, group, token, TAG_BYTES + 1)
    expect(status == 400 and json.loads(data) == {"error": "invalidRequest", "version": 2},
           "a blob path answers 400 invalidRequest through the control router")


def check_blobs_on() -> None:
    group, token = new_group()
    status, document = mls_call(ALLOWED, "capabilities", token, group=b64(group))
    expect(status == 200 and document.get("blobs") == BLOB_CAPABILITY, "capabilities advertise the blobs object")

    length = PART_BYTES + TAG_BYTES + 1
    expect(layout(length).parts == 2, "the round-trip object has two GSB1 parts")
    status, data, object_, parts = begin(ALLOWED, group, token, length)
    expect(status == 200 and json.loads(data)["complete"] is False, "begin is routed to the blob lane")
    for index, part in enumerate(parts):
        status, _, data = blob_part(ALLOWED, "put", group, object_, index, token, part)
        expect(status == 200 and json.loads(data) == {"version": 2, "stored": True, "complete": index == 1},
               f"part {index} of {len(part)} bytes is stored through Traefik buffering")
    status, headers, data = blob_part(ALLOWED, "get", group, object_, 1, token, headers={"X-GotSync-Route": "control"})
    expect(status == 200 and data == parts[1] and headers.get("Cache-Control") == "no-store"
           and headers.get("Content-Type") == "application/octet-stream",
           "a client X-GotSync-Route: control on a blob path is overwritten and the exact part is served")
    status, _, data = blob_call(ALLOWED, "manifest", token, group=b64(group), object=b64(object_))
    expect(status == 200 and json.loads(data)["complete"] is True, "the manifest reports the object complete")
    status, _, data = send_request(ALLOWED, "POST", "/v2/mls/fetch", b"{}", {"X-GotSync-Route": "blob"})
    expect(status == 400 and json.loads(data).get("version") == 2, "a control request with a blob tag stays control")

    try:
        status, _, data = send_request(ALLOWED, "POST", f"/v2/mls/blob/put/{b64(group)}/{b64(object_)}/0",
                                       headers=bearer(token), content_length=1_572_864,
                                       content_type="application/octet-stream")
    except OSError:
        status, data = 0, b""
    expect(status == 413 and not is_json(data), "Traefik refuses blob bodies over 1 MiB from the declared length")

    check_blob_in_flight(group, token)
    check_blob_rate(group, token)


def wanted(via: str, group: bytes, token: bytes) -> tuple[int, http.client.HTTPMessage, bytes]:
    return blob_call(via, "wanted", token, group=b64(group))


def proxy_in_flight_refusal(response: tuple[int, http.client.HTTPMessage, bytes]) -> bool:
    status, headers, data = response
    return status == 429 and not is_json(data) and "X-Retry-In" not in headers and "Retry-After" not in headers


def hold_blob_request(group: bytes, token: bytes) -> ssl.SSLSocket:
    sock = tls_socket(ALLOWED)
    sock.sendall(
        (
            f"POST /v2/mls/blob/put/{b64(group)}/{b64(os.urandom(32))}/0 HTTP/1.1\r\nHost: {HOST}\r\n"
            f"Authorization: Bearer {b64(token)}\r\n"
            "Content-Type: application/octet-stream\r\nContent-Length: 64\r\n\r\nx"
        ).encode()
    )
    return sock


def answered_early(held: list[ssl.SSLSocket]) -> list[bytes]:
    answers = []
    for sock in held:
        sock.setblocking(False)
        try:
            answers.append(sock.recv(120) or b"closed")
        except ssl.SSLWantReadError:
            pass
        except OSError as error:
            answers.append(repr(error).encode())
        finally:
            sock.settimeout(10)
    return answers


def in_flight_attempt(group: bytes, token: bytes) -> tuple[bool, list[bytes]]:
    """Holds four partial blob requests, then probes for Traefik's in-flight refusal; reports any held request
    that was answered before the probes, which would leave fewer than four in flight."""
    held = [hold_blob_request(group, token) for _ in range(4)]
    try:
        for _ in range(6):
            early = answered_early(held)
            if early:
                return False, early
            response = wanted(ALLOWED, group, token)
            if proxy_in_flight_refusal(response):
                status, _, data = send_request(ALLOWED, "POST", "/v2/mls/fetch", b"{}")
                expect(status == 400 and is_json(data), "control requests from the same source are unaffected")
                status, _, _ = wanted(DENIED, group, token)
                expect(status == 200, "blob requests from another source are unaffected")
                return True, []
            expect(response[0] == 200, "a probe before the held requests count is served by the relay")
            time.sleep(0.25)
        return False, answered_early(held)
    finally:
        for sock in held:
            sock.close()


def check_blob_in_flight(group: bytes, token: bytes) -> None:
    outcomes = []
    for _ in range(2):
        refused, early = in_flight_attempt(group, token)
        outcomes.append(early)
        if refused:
            break
        wait_for_blob_recovery(group, token)
    expect(refused, "Traefik's in-flight limiter (non-JSON 429 without rate headers) refuses a 5th concurrent "
           f"blob request (held requests answered early per attempt: {outcomes})")
    wait_for_blob_recovery(group, token)
    expect(True, "the source recovers once its blob requests finish")


def wait_for_blob_recovery(group: bytes, token: bytes) -> None:
    for _ in range(20):
        if wanted(ALLOWED, group, token)[0] == 200:
            return
        time.sleep(0.25)
    expect(False, "the source recovers once its blob requests finish")


def check_blob_rate(group: bytes, token: bytes) -> None:
    statuses = []
    for _ in range(80):
        status, headers, data = wanted(ALLOWED, group, token)
        statuses.append(status)
        if status != 200:
            break
    expect(status == 429 and not is_json(data) and "X-Retry-In" in headers and set(statuses[:-1]) == {200},
           f"Traefik's blob rate bucket refuses first, after {len(statuses) - 1} served requests")
    status, _, data = send_request(ALLOWED, "POST", "/v2/mls/fetch", b"{}")
    expect(status == 400 and is_json(data), "the control rate bucket is separate from the blob bucket")


def check_blobs_misrouted() -> None:
    group, token = new_group()
    for headers, message in (
        (None, "a blob request through the control router is refused as misrouted"),
        ({"X-GotSync-Route": "blob"}, "a spoofed X-GotSync-Route: blob through the control router is overwritten and refused"),
    ):
        status, data, _, _ = begin(ALLOWED, group, token, TAG_BYTES + 1, headers)
        expect_not_found(status, data, message)
    status, _, data = send_request(ALLOWED, "POST", "/v2/mls/fetch", b"{}")
    expect(status == 400 and is_json(data), "control requests are still served")


def check_blobs_downgraded() -> None:
    group, token = new_group()
    status, document = mls_call(ALLOWED, "capabilities", token, group=b64(group))
    expect(status == 200 and "blobs" not in document, "a relay with blobs disabled advertises no blobs capability")
    status, data, _, _ = begin(ALLOWED, group, token, TAG_BYTES + 1)
    expect(status == 400 and json.loads(data) == {"error": "invalidRequest", "version": 2},
           "the kept blob router reaches a relay that answers 400 invalidRequest")


if __name__ == "__main__":
    {
        "open": check_open,
        "admission": check_admission,
        "blobs-off": check_blobs_off,
        "blobs-on": check_blobs_on,
        "blobs-misrouted": check_blobs_misrouted,
        "blobs-downgraded": check_blobs_downgraded,
    }[sys.argv[1]]()
