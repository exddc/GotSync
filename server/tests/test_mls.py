import concurrent.futures
import sqlite3
import hashlib

import pytest

from gotsync_server.mls import MLSDeliveryStore, DeliveryConflict, DeliveryCapacity, DeliveryUnauthorized
from gotsync_server.mailbox import MailboxError, encode_base64url


def request(store, operation, **values):
    if operation in ("fetch", "ack"):
        values.setdefault("authorization", encode_base64url(b"a" * 32))
    if operation == "key-package/fetch":
        values.setdefault("pairingToken", encode_base64url(b"p" * 32))
    if operation == "key-package/publish":
        values.setdefault("pairingHash", encode_base64url(hashlib.sha256(b"p" * 32).digest()))
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
    assert fetched == [accepted["entry"], message["entry"]]
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
        assert columns == {"route", "epoch", "cursor", "kind", "payload", "welcome", "package", "reference", "expires", "digest", "writer", "removed_writer", "added_writer", "head", "ack", "removal", "removed_at", "pairing", "created_at"}
        assert db.execute("SELECT payload FROM mls_entries").fetchone()[0] == b"opaque MLS bytes"


def test_bounds_and_version(tmp_path, monkeypatch):
    store = MLSDeliveryStore(tmp_path / "mls.sqlite3")
    with pytest.raises(MailboxError):
        store.request("append", {"version": 1})
    with pytest.raises(MailboxError):
        append(store, epoch=True)
    with pytest.raises(MailboxError):
        append(store, payload=b"x" * (448 * 1024 + 1))
    monkeypatch.setattr("gotsync_server.mls.MAX_ENTRIES", 0)
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
    store.max_groups = 1
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
    from gotsync_server.mls import MLSDeliveryServer

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
            assert (await post("append", body)).startswith(b"HTTP/1.1 403")
            assert request(store, "fetch", group=group, after=0)["entries"] == []
            assert (await post("append", body, header)).startswith(b"HTTP/1.1 200")
        finally:
            await server.close()

    asyncio.run(run())


def test_http_internal_error_is_reported_and_handlers_drain(tmp_path, monkeypatch):
    import asyncio
    import json
    from gotsync_server.mls import MLSDeliveryServer

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


def test_authenticated_reads_and_single_use_pairing(tmp_path):
    store = MLSDeliveryStore(tmp_path / "mls.sqlite3")
    append(store)
    for token in (None, encode_base64url(b"outsider".ljust(32, b"!"))):
        with pytest.raises(DeliveryUnauthorized):
            request(store, "fetch", group=encode_base64url(b"g" * 32), after=0, authorization=token)
    reference = request(store, "key-package/publish", payload=encode_base64url(b"package"))["reference"]
    for token in (None, encode_base64url(b"wrong".ljust(32, b"!"))):
        with pytest.raises(DeliveryUnauthorized):
            request(store, "key-package/fetch", reference=reference, pairingToken=token)
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
        results = list(executor.map(lambda _: request(store, "key-package/fetch", reference=reference)["payload"], range(2)))
    assert results.count(encode_base64url(b"package")) == 1
    assert results.count(None) == 1
    append(store, payload=b"add after fetch", epoch=1, reference=reference, welcome=encode_base64url(b"welcome"))
    store.close()


def test_package_expiry(tmp_path, monkeypatch):
    monkeypatch.setattr("gotsync_server.mls.time.time", lambda: 1000)
    store = MLSDeliveryStore(tmp_path / "mls.sqlite3")
    reference = request(store, "key-package/publish", payload=encode_base64url(b"package"))["reference"]
    assert request(store, "key-package/fetch", reference=reference)["payload"] is not None
    monkeypatch.setattr("gotsync_server.mls.time.time", lambda: 1899)
    request(store, "key-package/publish", payload=encode_base64url(b"package"))
    assert request(store, "key-package/fetch", reference=reference)["payload"] is None
    monkeypatch.setattr("gotsync_server.mls.time.time", lambda: 1900)
    assert request(store, "key-package/fetch", reference=reference)["payload"] is None
    assert append(store, reference=reference, welcome=encode_base64url(b"welcome"))["error"] == "keyPackageUnavailable"
    store.close()


def removed_group(store):
    reference = request(store, "key-package/publish", payload=encode_base64url(b"package"))["reference"]
    append(store, reference=reference, welcome=encode_base64url(b"welcome"))
    return append(store, payload=b"remove", epoch=1, removeWriter=encode_base64url(hashlib.sha256(b"b" * 32).digest()))["entry"]["cursor"]


def test_removed_writer_final_read_ack_and_pruning(tmp_path):
    store = MLSDeliveryStore(tmp_path / "mls.sqlite3")
    cursor = removed_group(store)
    group = encode_base64url(b"g" * 32)
    bob = encode_base64url(b"b" * 32)
    append(store, payload=b"after removal", epoch=2, kind="application")
    request(store, "ack", route=group, cursor=cursor)
    assert len(request(store, "fetch", group=group, after=0)["entries"]) == 3
    entries = request(store, "fetch", group=group, after=0, authorization=bob)["entries"]
    assert entries[-1]["cursor"] == cursor
    with pytest.raises(MailboxError):
        request(store, "ack", route=group, cursor=cursor + 1, authorization=bob)
    request(store, "ack", route=group, cursor=cursor, authorization=bob)
    assert len(request(store, "fetch", group=group, after=0)["entries"]) == 1
    for operation, fields in (("fetch", {"group": group, "after": 0}), ("ack", {"route": group, "cursor": cursor})):
        with pytest.raises(DeliveryUnauthorized):
            request(store, operation, authorization=bob, **fields)
    store.close()


def test_removed_writer_floor_expires_after_day(tmp_path, monkeypatch):
    monkeypatch.setattr("gotsync_server.mls.time.time", lambda: 1000)
    store = MLSDeliveryStore(tmp_path / "mls.sqlite3")
    cursor = removed_group(store)
    group = encode_base64url(b"g" * 32)
    request(store, "ack", route=group, cursor=cursor)
    monkeypatch.setattr("gotsync_server.mls.time.time", lambda: 1000 + 86399)
    assert len(request(store, "fetch", group=group, after=0)["entries"]) == 2
    monkeypatch.setattr("gotsync_server.mls.time.time", lambda: 1000 + 86400)
    assert request(store, "fetch", group=group, after=0)["entries"] == []
    with pytest.raises(DeliveryUnauthorized):
        request(store, "fetch", group=group, after=0, authorization=encode_base64url(b"b" * 32))
    store.close()


def test_ack_floor_is_monotonic_and_route_local(tmp_path):
    store = MLSDeliveryStore(tmp_path / "mls.sqlite3")
    first = append(store, payload=b"first", kind="application")["entry"]["cursor"]
    last = append(store, payload=b"last", kind="application")["entry"]["cursor"]
    other = encode_base64url(b"h" * 32)
    token = encode_base64url(b"a" * 32)
    request(store, "create", group=other, authorization=token)
    request(store, "append", group=other, authorization=token, epoch=0, kind="application", payload=encode_base64url(b"other"))
    group = encode_base64url(b"g" * 32)
    with pytest.raises(MailboxError):
        request(store, "ack", route=group, cursor=last + 1)
    request(store, "ack", route=group, cursor=last)
    request(store, "ack", route=group, cursor=first)
    assert request(store, "fetch", group=group, after=0)["entries"] == []
    assert len(request(store, "fetch", group=other, after=0)["entries"]) == 1
    assert store._db.execute("SELECT ack FROM mls_writers WHERE route=?", (b"g" * 32,)).fetchone()[0] == last
    store.close()


def test_paging_defaults_bounds_and_order(tmp_path):
    store = MLSDeliveryStore(tmp_path / "mls.sqlite3")
    expected = [append(store, payload=bytes([i]), kind="application")["entry"] for i in range(35)]
    group = encode_base64url(b"g" * 32)
    assert request(store, "fetch", group=group, after=0)["entries"] == expected[:16]
    assert request(store, "fetch", group=group, after=0, limit=32)["entries"] == expected[:32]
    assert request(store, "fetch", group=group, after=expected[31]["cursor"], limit=32)["entries"] == expected[32:]
    for limit in (0, 33, True, -1, "16"):
        with pytest.raises(MailboxError):
            request(store, "fetch", group=group, after=0, limit=limit)
    store.close()


def test_capacity_is_per_route_and_counts_welcome_and_reference(tmp_path, monkeypatch):
    store = MLSDeliveryStore(tmp_path / "mls.sqlite3")
    monkeypatch.setattr("gotsync_server.mls.MAX_ENTRIES", 1)
    append(store, kind="application")
    other = encode_base64url(b"h" * 32)
    token = encode_base64url(b"a" * 32)
    request(store, "create", group=other, authorization=token)
    request(store, "append", group=other, authorization=token, epoch=0, kind="application", payload=encode_base64url(b"other"))
    with pytest.raises(DeliveryCapacity):
        append(store, payload=b"full", kind="application")
    request(store, "ack", route=encode_base64url(b"g" * 32), cursor=1)
    reference = request(store, "key-package/publish", payload=encode_base64url(b"package"))["reference"]
    monkeypatch.setattr("gotsync_server.mls.MAX_BYTES", 33)
    with pytest.raises(DeliveryCapacity):
        append(store, payload=b"p", reference=reference, welcome=encode_base64url(b"w"))
    monkeypatch.setattr("gotsync_server.mls.MAX_BYTES", 34)
    append(store, payload=b"p", reference=reference, welcome=encode_base64url(b"w"))
    store.close()


@pytest.mark.parametrize("production", [False, True])
def test_http_mount_auth_paging_ack_and_threaded_store(tmp_path, monkeypatch, production):
    import asyncio
    import json
    import threading
    from gotsync_server.mls import MLSDeliveryServer
    from gotsync_server.server import RelayServer

    async def run():
        if production:
            server = RelayServer(port=0, metrics_port=0, mailbox_port=0, mailbox_database_path=tmp_path / "mailbox.sqlite3")
            await server.start()
            port = server.bound_mailbox_port
            store = server.mls.store
        else:
            store = MLSDeliveryStore(tmp_path / "mls.sqlite3")
            server = MLSDeliveryServer(store)
            port = await server.start()
        event_thread = threading.get_ident()
        original = store.request
        threads = []
        def tracked(*args):
            threads.append(threading.get_ident())
            return original(*args)
        monkeypatch.setattr(store, "request", tracked)

        async def post(operation, values, token=None):
            reader, writer = await asyncio.open_connection("127.0.0.1", port)
            body = json.dumps({"version": 2, **values}).encode()
            header = f"Authorization: Bearer {token}\r\n" if token else ""
            writer.write((f"POST /v2/mls/{operation} HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: {len(body)}\r\n" + header + "\r\n").encode() + body)
            await writer.drain()
            response = await asyncio.wait_for(reader.read(), 3)
            writer.close()
            await writer.wait_closed()
            head, body = response.split(b"\r\n\r\n", 1)
            return int(head.split()[1]), json.loads(body)

        try:
            group = encode_base64url(b"g" * 32)
            token = encode_base64url(b"a" * 32)
            assert (await post("create", {"group": group}, token))[0] == 200
            status, body = await post("fetch", {"group": group, "after": 0, "authorization": token})
            assert status == 403 and body["version"] == 2
            for i in range(2):
                assert (await post("append", {"group": group, "epoch": 0, "kind": "application", "payload": encode_base64url(b"x" * (448 * 1024) if i else b"first")}, token))[0] == 200
            status, body = await post("fetch", {"group": group, "after": 0}, token)
            assert status == 200 and len(body["entries"]) == 2
            assert (await post("ack", {"route": group, "cursor": body["entries"][-1]["cursor"]}, token))[0] == 200
            assert (await post("fetch", {"group": group, "after": 0}, token))[1]["entries"] == []
            assert threads and event_thread not in threads
            assert (tmp_path / "mls.sqlite3").exists()
            def fail(*args):
                raise sqlite3.OperationalError("injected storage failure")
            monkeypatch.setattr(store, "request", fail)
            status, body = await post("fetch", {"group": group, "after": 0}, token)
            assert status == 500 and body["version"] == 2
        finally:
            await server.close()

    asyncio.run(run())


def test_directory_constructor_limits_and_package_expiry(tmp_path, monkeypatch):
    monkeypatch.setattr("gotsync_server.mls.time.time", lambda: 1000)
    store = MLSDeliveryStore(tmp_path / "mls.sqlite3", max_groups=1, max_packages=1)
    append(store, kind="application")
    with pytest.raises(DeliveryCapacity):
        request(store, "create", group=encode_base64url(b"h" * 32), authorization=encode_base64url(b"a" * 32))
    request(store, "key-package/publish", payload=encode_base64url(b"first package"))
    with pytest.raises(DeliveryCapacity):
        request(store, "key-package/publish", payload=encode_base64url(b"second package"))
    monkeypatch.setattr("gotsync_server.mls.time.time", lambda: 1900)
    request(store, "key-package/publish", payload=encode_base64url(b"second package"))
    store.close()


def test_empty_groups_expire_without_deleting_used_groups(tmp_path, monkeypatch):
    monkeypatch.setattr("gotsync_server.mls.time.time", lambda: 1000)
    store = MLSDeliveryStore(tmp_path / "mls.sqlite3")
    assert store.max_groups == store.max_packages == 4096
    empty = encode_base64url(b"h" * 32)
    token = encode_base64url(b"a" * 32)
    request(store, "create", group=empty, authorization=token)
    entry = append(store, kind="application")["entry"]
    group = encode_base64url(b"g" * 32)
    monkeypatch.setattr("gotsync_server.mls.time.time", lambda: 1000 + 86399)
    assert request(store, "fetch", group=group, after=0)["entries"] == [entry]
    assert store._db.execute("SELECT COUNT(*) FROM mls_groups").fetchone()[0] == 2
    monkeypatch.setattr("gotsync_server.mls.time.time", lambda: 1000 + 86400)
    assert request(store, "fetch", group=group, after=0)["entries"] == [entry]
    assert store._db.execute("SELECT route FROM mls_groups").fetchall() == [(b"g" * 32,)]
    assert store._db.execute("SELECT route FROM mls_writers").fetchall() == [(b"g" * 32,)]
    request(store, "ack", route=group, cursor=entry["cursor"])
    monkeypatch.setattr("gotsync_server.mls.time.time", lambda: 1000 + 2 * 86400)
    assert request(store, "fetch", group=group, after=0)["entries"] == []
    assert store._db.execute("SELECT route FROM mls_groups").fetchall() == [(b"g" * 32,)]
    request(store, "create", group=empty, authorization=encode_base64url(b"c" * 32))
    store.close()


def test_joiner_floor_keeps_welcome_but_releases_earlier_entries(tmp_path):
    store = MLSDeliveryStore(tmp_path / "mls.sqlite3")
    append(store, payload=b"before welcome", kind="application")
    reference = request(store, "key-package/publish", payload=encode_base64url(b"package"))["reference"]
    welcome = append(store, reference=reference, welcome=encode_base64url(b"welcome"))["entry"]
    group = encode_base64url(b"g" * 32)
    request(store, "ack", route=group, cursor=welcome["cursor"])
    assert request(store, "fetch", group=group, after=0)["entries"] == [welcome]
    request(store, "ack", route=group, cursor=welcome["cursor"], authorization=encode_base64url(b"b" * 32))
    assert request(store, "fetch", group=group, after=0)["entries"] == []
    store.close()


def test_leave_proposal_revokes_its_sender_and_a_later_commit_removes_it(tmp_path):
    store = MLSDeliveryStore(tmp_path / "mls.sqlite3")
    removed_group(store)
    group = encode_base64url(b"g" * 32)
    alice = encode_base64url(b"a" * 32)
    carol = encode_base64url(b"c" * 32)
    carol_hash = encode_base64url(hashlib.sha256(b"c" * 32).digest())
    package = request(store, "key-package/publish", payload=encode_base64url(b"carol package"), authorization=carol)["reference"]
    append(store, payload=b"add carol", epoch=2, reference=package, welcome=encode_base64url(b"welcome"), addWriter=carol_hash)
    for fields in ({"removeWriter": carol_hash}, {"addWriter": carol_hash}):
        with pytest.raises(MailboxError):
            append(store, payload=b"bad proposal", epoch=3, kind="proposal", authorization=carol, **fields)
    with pytest.raises(DeliveryConflict):
        append(store, payload=b"stale leave", epoch=2, kind="proposal", authorization=carol)
    left = append(store, payload=b"carol leaves", epoch=3, kind="proposal", authorization=carol)["entry"]
    assert left["kind"] == "proposal"
    for payload, kind in ((b"carol leaves", "proposal"), (b"after leaving", "application")):
        with pytest.raises(DeliveryUnauthorized):
            append(store, payload=payload, epoch=3, kind=kind, authorization=carol)
    assert request(store, "fetch", group=group, after=0, authorization=carol)["entries"][-1] == left
    request(store, "ack", route=group, cursor=left["cursor"], authorization=carol)
    for operation, fields in (("fetch", {"group": group, "after": 0}), ("ack", {"route": group, "cursor": left["cursor"]})):
        with pytest.raises(DeliveryUnauthorized):
            request(store, operation, authorization=carol, **fields)
    committed = append(store, payload=b"commit carol removal", epoch=3, removeWriter=carol_hash, authorization=alice)["entry"]
    assert committed["epoch"] == 3
    after = append(store, payload=b"later epoch", epoch=4, kind="application")["entry"]
    assert request(store, "fetch", group=group, after=0)["entries"][-2:] == [committed, after]
    removal = store._db.execute("SELECT removal FROM mls_writers WHERE digest=?", (hashlib.sha256(b"c" * 32).digest(),)).fetchone()[0]
    assert removal == left["cursor"]
    store.close()


def test_removed_writer_cannot_read_or_write_later_epochs(tmp_path):
    store = MLSDeliveryStore(tmp_path / "mls.sqlite3")
    cursor = removed_group(store)
    group = encode_base64url(b"g" * 32)
    bob = encode_base64url(b"b" * 32)
    append(store, payload=b"later epoch", epoch=2, kind="application")
    assert [entry["cursor"] for entry in request(store, "fetch", group=group, after=0, authorization=bob)["entries"]][-1] == cursor
    assert request(store, "fetch", group=group, after=cursor, authorization=bob)["entries"] == []
    for kind in ("application", "proposal", "commit"):
        with pytest.raises(DeliveryUnauthorized):
            append(store, payload=b"removed " + kind.encode(), epoch=2, kind=kind, authorization=bob)
    store.close()
