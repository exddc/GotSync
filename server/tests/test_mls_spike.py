import concurrent.futures
import sqlite3
import hashlib

import pytest

from gotsync_server.mls_spike import MLSDeliveryStore, DeliveryConflict, DeliveryCapacity, DeliveryUnauthorized
from gotsync_server.mailbox import MailboxError, encode_base64url


def request(store, operation, **values):
    if operation == "key-package/publish":
        values.setdefault("authorization", encode_base64url(b"b" * 32))
    return store.request(operation, {"version": 2, **values})


def append(store, payload=b"encrypted commit", epoch=0, kind="commit", **values):
    request(store, "create", group=encode_base64url(b"g" * 32), authorization=encode_base64url(b"a" * 32))
    values.setdefault("authorization", encode_base64url(b"a" * 32))
    if values.get("welcome") is not None:
        values.setdefault("addWriter", encode_base64url(hashlib.sha256(b"b" * 32).digest()))
    return request(store, "append", group=encode_base64url(b"g" * 32), epoch=epoch,
                   kind=kind, payload=encode_base64url(payload), **values)


def test_epoch_order_idempotency_and_atomic_welcome(tmp_path):
    store = MLSDeliveryStore(tmp_path / "mls.sqlite3")
    package = request(store, "key-package/publish", payload=encode_base64url(b"public key package"))["reference"]
    accepted = append(store, reference=package, welcome=encode_base64url(b"encrypted welcome"))
    assert append(store, reference=package, welcome=encode_base64url(b"encrypted welcome")) == accepted
    assert request(store, "key-package/fetch", reference=package)["payload"] is None
    with pytest.raises(DeliveryConflict):
        append(store, payload=b"competing commit")
    with pytest.raises(DeliveryConflict):
        append(store, payload=b"stale application", kind="application")
    message = append(store, payload=b"encrypted application", epoch=1, kind="application")
    fetched = request(store, "fetch", group=encode_base64url(b"g" * 32), after=0)["entries"]
    assert fetched == [accepted["entry"]]
    store.close()
    store = MLSDeliveryStore(tmp_path / "mls.sqlite3")
    assert request(store, "fetch", group=encode_base64url(b"g" * 32), after=fetched[0]["cursor"])["entries"] == [message["entry"]]
    store.close()


def test_competing_commits_only_one_wins(tmp_path):
    store = MLSDeliveryStore(tmp_path / "mls.sqlite3")
    def attempt(value):
        try:
            return append(store, payload=value)
        except DeliveryConflict:
            return None
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
        results = list(executor.map(attempt, [b"first", b"second"]))
    assert sum(result is not None for result in results) == 1
    store.close()


def test_rejected_append_does_not_consume_package(tmp_path):
    store = MLSDeliveryStore(tmp_path / "mls.sqlite3")
    package = request(store, "key-package/publish", payload=encode_base64url(b"public key package"))["reference"]
    append(store)
    with pytest.raises(DeliveryConflict):
        append(store, payload=b"losing commit", reference=package, welcome=encode_base64url(b"welcome"))
    assert request(store, "key-package/fetch", reference=package)["payload"] is not None
    store.close()


def test_no_crypto_secrets_in_delivery_schema(tmp_path):
    path = tmp_path / "mls.sqlite3"
    store = MLSDeliveryStore(path)
    append(store, payload=b"opaque MLS bytes")
    store.close()
    with sqlite3.connect(path) as db:
        columns = {row[1] for table in ("mls_groups", "mls_entries", "mls_packages", "mls_rejections", "mls_writers")
                   for row in db.execute(f"PRAGMA table_info({table})")}
        assert columns == {"route", "epoch", "cursor", "kind", "payload", "welcome", "package", "reference", "expires", "digest", "writer", "removed_writer", "added_writer"}
        assert db.execute("SELECT payload FROM mls_entries").fetchone()[0] == b"opaque MLS bytes"


def test_bounds_and_version(tmp_path, monkeypatch):
    store = MLSDeliveryStore(tmp_path / "mls.sqlite3")
    with pytest.raises(MailboxError):
        store.request("append", {"version": 1})
    with pytest.raises(MailboxError):
        append(store, epoch=True)
    with pytest.raises(MailboxError):
        append(store, payload=b"x" * (448 * 1024 + 1))
    monkeypatch.setattr("gotsync_server.mls_spike.MAX_ENTRIES", 0)
    with pytest.raises(DeliveryCapacity):
        append(store)
    store.close()


def test_unauthorized_and_removed_writers_cannot_advance_epoch(tmp_path):
    store = MLSDeliveryStore(tmp_path / "mls.sqlite3")
    group = encode_base64url(b"g" * 32)
    bob = encode_base64url(b"b" * 32)
    with pytest.raises(DeliveryUnauthorized):
        append(store, authorization=bob)
    assert request(store, "fetch", group=group, after=0)["entries"] == []
    package = request(store, "key-package/publish", payload=encode_base64url(b"public package"))["reference"]
    append(store, reference=package, welcome=encode_base64url(b"welcome"))
    append(store, payload=b"bob edit", epoch=1, kind="application", authorization=bob)
    append(store, payload=b"remove bob", epoch=1, removeWriter=encode_base64url(hashlib.sha256(b"b" * 32).digest()))
    with pytest.raises(DeliveryUnauthorized):
        append(store, payload=b"poison epoch", epoch=2, authorization=bob)
    append(store, payload=b"alice edit", epoch=2, kind="application")
    store.close()


def test_writer_metadata_retries_and_group_capacity(tmp_path, monkeypatch):
    store = MLSDeliveryStore(tmp_path / "mls.sqlite3")
    payload = encode_base64url(b"public package")
    package = request(store, "key-package/publish", payload=payload)["reference"]
    with pytest.raises(DeliveryConflict):
        request(store, "key-package/publish", payload=payload, authorization=encode_base64url(b"c" * 32))
    with pytest.raises(MailboxError):
        append(store, reference=package, welcome=encode_base64url(b"welcome"), removeWriter=encode_base64url(b"unknown".ljust(32, b"!")))
    assert request(store, "key-package/fetch", reference=package)["payload"] == payload
    append(store, reference=package, welcome=encode_base64url(b"welcome"))
    removed = encode_base64url(hashlib.sha256(b"b" * 32).digest())
    accepted = append(store, payload=b"remove bob", epoch=1, removeWriter=removed)
    assert append(store, payload=b"remove bob", epoch=1, removeWriter=removed) == accepted
    with pytest.raises(DeliveryConflict):
        append(store, payload=b"remove bob", epoch=1)
    monkeypatch.setattr("gotsync_server.mls_spike.MAX_GROUPS", 1)
    with pytest.raises(DeliveryCapacity):
        request(store, "create", group=encode_base64url(b"new".ljust(32, b"!")), authorization=encode_base64url(b"a" * 32))
    store.close()


def test_key_package_writer_mismatch_is_terminal(tmp_path):
    store = MLSDeliveryStore(tmp_path / "mls.sqlite3")
    package = request(store, "key-package/publish", payload=encode_base64url(b"public package"))["reference"]
    refused = append(store, reference=package, welcome=encode_base64url(b"welcome"), addWriter=encode_base64url(b"wrong".ljust(32, b"!")))
    assert refused == {"version": 2, "error": "keyPackageUnavailable", "epoch": 0}
    assert append(store, reference=package, welcome=encode_base64url(b"welcome")) == refused
    assert request(store, "fetch", group=encode_base64url(b"g" * 32), after=0)["entries"] == []
    assert request(store, "key-package/fetch", reference=package)["payload"] is not None
    store.close()


def test_writer_capacity_does_not_consume_package(tmp_path):
    store = MLSDeliveryStore(tmp_path / "mls.sqlite3")
    for index in range(7):
        token = bytes([index + 2]) * 32
        package = request(store, "key-package/publish", payload=encode_base64url(token), authorization=encode_base64url(token))["reference"]
        append(store, payload=token, epoch=index, reference=package, welcome=encode_base64url(b"welcome"),
               addWriter=encode_base64url(hashlib.sha256(token).digest()))
    package = request(store, "key-package/publish", payload=encode_base64url(b"ninth package"))["reference"]
    with pytest.raises(DeliveryCapacity):
        append(store, payload=b"ninth", epoch=7, reference=package, welcome=encode_base64url(b"welcome"))
    assert request(store, "key-package/fetch", reference=package)["payload"] is not None
    store.close()


def test_http_bearer_case_and_body_authorization(tmp_path):
    import asyncio
    import json
    from gotsync_server.mls_spike import MLSDeliveryServer

    async def run():
        store = MLSDeliveryStore(tmp_path / "mls.sqlite3")
        server = MLSDeliveryServer(store)
        port = await server.start()

        async def post(operation, values, header=b""):
            reader, writer = await asyncio.open_connection("127.0.0.1", port)
            body = json.dumps({"version": 2, **values}).encode()
            writer.write(f"POST /v2/mls/{operation} HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: {len(body)}\r\n".encode()
                         + header + b"\r\n" + body)
            await writer.drain()
            response = await asyncio.wait_for(reader.read(), 3)
            writer.close()
            await writer.wait_closed()
            return response

        try:
            group = encode_base64url(b"g" * 32)
            token = encode_base64url(b"a" * 32)
            header = f"Authorization: bearer {token}\r\n".encode()
            assert (await post("create", {"group": group}, header)).startswith(b"HTTP/1.1 200")
            body = {"group": group, "epoch": 0, "kind": "commit", "payload": encode_base64url(b"opaque"), "authorization": token}
            assert (await post("append", body)).startswith(b"HTTP/1.1 400")
            assert request(store, "fetch", group=group, after=0)["entries"] == []
            assert (await post("append", body, header)).startswith(b"HTTP/1.1 200")
        finally:
            await server.close()

    asyncio.run(run())


def test_http_internal_error_is_reported_and_handlers_drain(tmp_path, monkeypatch):
    import asyncio
    import json
    from gotsync_server.mls_spike import MLSDeliveryServer

    async def run():
        store = MLSDeliveryStore(tmp_path / "mls.sqlite3")
        server = MLSDeliveryServer(store)
        port = await server.start()
        try:
            def fail(*args):
                raise sqlite3.OperationalError("injected storage failure")
            monkeypatch.setattr(store, "_request", fail)
            reader, writer = await asyncio.open_connection("127.0.0.1", port)
            body = json.dumps({"version": 2}).encode()
            writer.write(b"POST /v2/mls/fetch HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: "
                         + str(len(body)).encode() + b"\r\n\r\n" + body)
            await writer.drain()
            response = await asyncio.wait_for(reader.read(), 3)
            assert response.startswith(b"HTTP/1.1 500")
            writer.close()
            await writer.wait_closed()
        finally:
            await server.close()
        assert not server._tasks

    asyncio.run(run())


def test_missing_package_rejection_is_terminal_even_after_republish(tmp_path):
    import hashlib
    store = MLSDeliveryStore(tmp_path / "mls.sqlite3")
    package = b"public key package"
    reference = encode_base64url(hashlib.sha256(package).digest())
    rejected = append(store, reference=reference, welcome=encode_base64url(b"welcome"))
    assert rejected == {"version": 2, "error": "keyPackageUnavailable", "epoch": 0}
    request(store, "key-package/publish", payload=encode_base64url(package))
    assert append(store, reference=reference, welcome=encode_base64url(b"welcome")) == rejected
    assert request(store, "key-package/fetch", reference=reference)["payload"] is not None
    assert request(store, "fetch", group=encode_base64url(b"g" * 32), after=0)["entries"] == []
    store.close()
