import concurrent.futures
import sqlite3

import pytest

from gotsync_server.mls_spike import MLSDeliveryStore, DeliveryConflict, DeliveryCapacity
from gotsync_server.mailbox import MailboxError, encode_base64url


def request(store, operation, **values):
    return store.request(operation, {"version": 2, **values})


def append(store, payload=b"encrypted commit", epoch=0, kind="commit", **values):
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
        columns = {row[1] for table in ("mls_groups", "mls_entries", "mls_packages", "mls_rejections")
                   for row in db.execute(f"PRAGMA table_info({table})")}
        assert columns == {"route", "epoch", "cursor", "kind", "payload", "welcome", "package", "reference", "expires", "digest"}
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
