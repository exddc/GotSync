import asyncio
import concurrent.futures
import contextlib
import dataclasses
import hashlib
import json
import sqlite3
import threading
import time
from contextlib import contextmanager

import pytest

from gotsync_server.admission import parse_network
from gotsync_server.blob import BlobLimits, BlobStore, BlobStoreCorrupt
from gotsync_server.blob_format import PART_BYTES
from gotsync_server.blob_http import BlobLaneConfig, ControlDispatcher
from gotsync_server.http import encode_base64url
from gotsync_server.server import RelayServer

from test_blob import ProbeFiles, make_object

WAIT = 10
A_TOKEN, B_TOKEN = b"a" * 32, b"b" * 32
B_DIGEST = hashlib.sha256(B_TOKEN).digest()
GROUP = b"g" * 32


def b64(value):
    return encode_base64url(value)


def mls(store, operation, **values):
    return store.request(operation, {"version": 2, **values})


def setup_group(store, group=GROUP):
    """Writer A creates the group and adds writer B (epoch 1)."""
    mls(store, "create", group=b64(group), authorization=b64(A_TOKEN))
    package = mls(store, "key-package/publish", payload=b64(b"package " + group), authorization=b64(B_TOKEN),
                  pairingHash=b64(hashlib.sha256(b"p" * 32).digest()))["reference"]
    mls(store, "append", group=b64(group), epoch=0, kind="commit", payload=b64(b"add b " + group), reference=package,
        welcome=b64(b"welcome"), addWriter=b64(B_DIGEST), authorization=b64(A_TOKEN))


def remove_b(store, group=GROUP):
    mls(store, "append", group=b64(group), epoch=1, kind="commit", payload=b64(b"remove b"),
        removeWriter=b64(B_DIGEST), authorization=b64(A_TOKEN))


class Response:
    def __init__(self, raw):
        head, _, self.body = raw.partition(b"\r\n\r\n")
        lines = head.decode().split("\r\n")
        self.status = int(lines[0].split()[1]) if lines[0] else 0
        self.headers = {line.split(":", 1)[0].lower(): line.split(":", 1)[1].strip() for line in lines[1:] if ":" in line}

    @property
    def json(self):
        return json.loads(self.body)


async def http(port, path, *, body=b"", token=B_TOKEN, content_length=None, send_body=True, headers=None,
               method="POST", content_type="application/json"):
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    lines = [f"{method} {path} HTTP/1.1", f"Content-Length: {len(body) if content_length is None else content_length}"]
    if content_type:
        lines.append(f"Content-Type: {content_type}")
    if token is not None:
        lines.append(f"Authorization: Bearer {b64(token)}")
    lines += [f"{name}: {value}" for name, value in (headers or {}).items()]
    writer.write(("\r\n".join(lines) + "\r\n\r\n").encode() + (body if send_body else b""))
    await writer.drain()
    try:
        raw = await asyncio.wait_for(reader.read(), WAIT)
    except ConnectionResetError:
        raw = b""
    finally:
        writer.close()
        with contextlib.suppress(ConnectionError):
            await writer.wait_closed()
    return Response(raw)


async def blob_json(port, operation, token=B_TOKEN, **values):
    return await http(port, f"/v2/mls/blob/{operation}", body=json.dumps({"version": 2, **values}).encode(), token=token)


async def put(port, object_, index, part, token=B_TOKEN, group=GROUP):
    return await http(port, f"/v2/mls/blob/put/{b64(group)}/{b64(object_)}/{index}", body=part, token=token,
                      content_type="application/octet-stream")


async def get(port, object_, index, token=B_TOKEN, group=GROUP):
    return await http(port, f"/v2/mls/blob/get/{b64(group)}/{b64(object_)}/{index}", token=token, content_type=None)


async def control_append(port, payload):
    body = json.dumps({"version": 2, "group": b64(GROUP), "epoch": 1, "kind": "application",
                       "payload": b64(payload)}).encode()
    return await http(port, "/v2/mls/append", body=body, token=A_TOKEN)


class PausedCommitStore(BlobStore):
    """Pauses an ordinary (metadata) transaction after its statements, before COMMIT, while holding the blob lock."""

    pause = None

    @contextmanager
    def _transaction(self, *, ownership=False):
        with super()._transaction(ownership=ownership) as db:
            yield db
            pause = self.pause
            if pause is not None and not ownership:
                self.pause = None
                pause[0].set()
                assert pause[1].wait(WAIT)


class Relay:
    def __init__(self, tmp_path, *, blob=True, files=ProbeFiles, store_class=BlobStore, **options):
        self.probes = []

        def open_store(database, directory, limits):
            def factory(path):
                probe = files(path)
                self.probes.append(probe)
                return probe
            store = store_class(database, directory, limits=limits, files=factory)
            self.probes[-1].store = store
            return store

        config = BlobLaneConfig(database=tmp_path / "blobs.sqlite3", directory=tmp_path / "blobs",
                                open_store=open_store, **options) if blob else None
        self.server = RelayServer(port=0, metrics_port=0, delivery_port=0,
                                  delivery_database_path=tmp_path / "mls.sqlite3", blob=config)

    async def __aenter__(self):
        await self.server.start()
        setup_group(self.server.mls.store)
        return self

    async def __aexit__(self, *_):
        await self.server.close()

    @property
    def port(self):
        return self.server.bound_delivery_port

    @property
    def lane(self):
        return self.server.blob

    @property
    def store(self):
        return self.server.blob.store

    async def ledger(self):
        return await asyncio.to_thread(self.store.ledger)

    def permits(self):
        return self.lane._permits.snapshot()


async def begin_object(relay, length, seed=b""):
    object_, hashes, parts = make_object(length, seed, route=GROUP)
    response = await blob_json(relay.port, "begin", group=b64(GROUP), object=b64(object_), length=length,
                               parts=[b64(value) for value in hashes])
    assert response.status == 200, response.body
    return object_, hashes, parts


def run(coroutine):
    return asyncio.run(coroutine)


# Disabled behavior and capabilities


def test_disabled_relay_answers_blob_paths_and_capabilities_as_before(tmp_path):
    async def main():
        relay = RelayServer(port=0, metrics_port=0, delivery_port=0, delivery_database_path=tmp_path / "mls.sqlite3")
        await relay.start()
        try:
            setup_group(relay.mls.store)
            port = relay.bound_delivery_port
            begin = await blob_json(port, "begin", group=b64(GROUP), object=b64(b"o" * 32), length=17, parts=[b64(b"h" * 32)])
            assert (begin.status, begin.json) == (400, {"error": "invalidRequest", "version": 2})
            binary = await http(port, f"/v2/mls/blob/put/{b64(GROUP)}/{b64(b'o' * 32)}/0", body=b"x" * 17)
            assert (binary.status, binary.json) == (400, {"error": "invalidRequest", "version": 2})
            capabilities = await http(port, "/v2/mls/capabilities", body=json.dumps({"version": 2, "group": b64(GROUP)}).encode())
            assert capabilities.json == {"conditionalAppend": True, "version": 2}
            assert relay.blob is None and not (tmp_path / "blobs.sqlite3").exists()
        finally:
            await relay.close()
    run(main())


def test_enabled_capabilities_round_trip_and_stored_retry(tmp_path):
    async def main():
        async with Relay(tmp_path) as relay:
            capabilities = await http(relay.port, "/v2/mls/capabilities",
                                      body=json.dumps({"version": 2, "group": b64(GROUP)}).encode())
            assert capabilities.json["blobs"] == {
                "version": 1, "partBytes": 524304, "maxObjectBytes": 10486080, "maxParts": 20,
                "groupQuotaBytes": 201326592, "retentionSeconds": 2592000, "incompleteSeconds": 86400}
            object_, hashes, parts = await begin_object(relay, PART_BYTES + 17, b"round")
            first = await put(relay.port, object_, 0, parts[0])
            assert (first.status, first.json) == (200, {"version": 2, "stored": True, "complete": False})
            again = await http(relay.port, f"/v2/mls/blob/put/{b64(GROUP)}/{b64(object_)}/0",
                               content_length=PART_BYTES, send_body=False, content_type="application/octet-stream")
            assert again.json == {"version": 2, "stored": True, "complete": False}
            assert (await put(relay.port, object_, 1, parts[1])).json["complete"] is True
            manifest = await blob_json(relay.port, "manifest", group=b64(GROUP), object=b64(object_))
            assert manifest.json == {"version": 2, "length": PART_BYTES + 17,
                                     "parts": [b64(value) for value in hashes], "present": [0, 1], "complete": True}
            fetched = await get(relay.port, object_, 1)
            assert fetched.status == 200 and fetched.body == parts[1]
            assert fetched.headers["content-type"] == "application/octet-stream"
            assert fetched.headers["cache-control"] == "no-store"
            missing = b"m" * 32
            assert (await blob_json(relay.port, "want", group=b64(GROUP), objects=[b64(missing)])).json == {
                "version": 2, "accepted": 1}
            assert (await blob_json(relay.port, "wanted", group=b64(GROUP))).json == {"version": 2, "objects": [b64(missing)]}
            assert (await blob_json(relay.port, "release", group=b64(GROUP), objects=[b64(object_)])).json == {"version": 2}
            assert relay.permits()["sets"] == 0
    run(main())


# Pipelines: parse before auth, auth before body


def test_binary_requests_are_refused_before_any_body_byte(tmp_path):
    async def main():
        async with Relay(tmp_path) as relay:
            object_, _, parts = await begin_object(relay, PART_BYTES, b"binary")
            path = f"/v2/mls/blob/put/{b64(GROUP)}/{b64(object_)}/0"
            unauthenticated = await http(relay.port, path, content_length=PART_BYTES, send_body=False, token=b"z" * 32,
                                         content_type="application/octet-stream")
            assert (unauthenticated.status, unauthenticated.json["error"]) == (403, "unauthorized")
            too_large = await http(relay.port, path, content_length=PART_BYTES + 1, send_body=False,
                                   content_type="application/octet-stream")
            assert (too_large.status, too_large.json["error"]) == (413, "requestTooLarge")
            wrong_size = await http(relay.port, path, content_length=PART_BYTES - 1, send_body=False,
                                    content_type="application/octet-stream")
            assert (wrong_size.status, wrong_size.json["error"]) == (400, "invalidRequest")
            remove_b(relay.server.mls.store)
            removed = await http(relay.port, path, content_length=PART_BYTES, send_body=False,
                                 content_type="application/octet-stream")
            assert (removed.status, removed.json["error"]) == (403, "unauthorized")
            assert (await relay.ledger())["outstanding"] == 0 and relay.permits()["sets"] == 0
            missing_group = await http(relay.port, f"/v2/mls/blob/put/{b64(b'x' * 32)}/{b64(object_)}/0",
                                       content_length=PART_BYTES, send_body=False, content_type="application/octet-stream")
            assert (missing_group.status, missing_group.json["error"]) == (410, "historyExpired")
            del parts
    run(main())


def test_metadata_is_parsed_within_4096_bytes_before_authorization(tmp_path, monkeypatch):
    async def main():
        async with Relay(tmp_path) as relay:
            calls = []
            original = relay.store.begin
            monkeypatch.setattr(relay.store, "begin", lambda *a, **k: (calls.append(True), original(*a, **k))[1])
            object_, hashes, _ = make_object(17, b"meta", route=GROUP)
            document = {"version": 2, "group": b64(GROUP), "object": b64(object_), "length": 17,
                        "parts": [b64(hashes[0])]}
            body = json.dumps(document).encode()
            body += b" " * (4096 - len(body))
            refused = await http(relay.port, "/v2/mls/blob/begin", body=body, token=b"z" * 32)
            assert (refused.status, refused.json["error"]) == (403, "unauthorized") and calls == []
            too_large = await http(relay.port, "/v2/mls/blob/begin", content_length=4097, send_body=False)
            assert (too_large.status, too_large.json["error"]) == (413, "requestTooLarge") and calls == []
            unknown = await blob_json(relay.port, "begin", group=b64(GROUP), object=b64(object_), length=17,
                                      parts=[b64(hashes[0])], extra=1)
            assert unknown.status == 400 and calls == []
            assert (await http(relay.port, "/v2/mls/blob/begin", body=body)).status == 200 and calls == [True]
    run(main())


# First-active authorization and writer permits


def pause_after_authorization(relay, monkeypatch, count):
    store = relay.server.mls.store
    original = store.authorize_active
    entered, release = threading.Semaphore(0), threading.Event()
    threads = []

    def paused(*args, **kwargs):
        digest = original(*args, **kwargs)
        threads.append(threading.current_thread().name)
        if len(threads) <= count:
            entered.release()
            assert release.wait(WAIT)
        return digest

    monkeypatch.setattr(store, "authorize_active", paused)
    return entered, release, threads


def test_requests_admitted_before_removal_finish_and_later_ones_are_refused(tmp_path, monkeypatch):
    async def main():
        async with Relay(tmp_path) as relay:
            object_, _, parts = await begin_object(relay, PART_BYTES * 2, b"removal")
            threads = record_authorization_threads(relay, monkeypatch)
            entered, release = pause_store_call(relay, monkeypatch, "admit_put", count=2)
            first = asyncio.ensure_future(put(relay.port, object_, 0, parts[0]))
            second = asyncio.ensure_future(put(relay.port, object_, 1, parts[1]))
            for _ in range(2):
                assert await asyncio.to_thread(entered.acquire, True, WAIT)
            third = await blob_json(relay.port, "manifest", group=b64(GROUP), object=b64(object_))
            assert (third.status, third.json["error"]) == (429, "blobBusy") and third.headers["retry-after"] == "1"
            started = time.monotonic()
            await asyncio.to_thread(remove_b, relay.server.mls.store)
            assert time.monotonic() - started < 1
            release.set()
            assert (await first).json["stored"] is True and (await second).json["stored"] is True
            manifest = await asyncio.to_thread(relay.store.manifest, GROUP, object_)
            assert manifest["complete"] is True
            later = await blob_json(relay.port, "manifest", group=b64(GROUP), object=b64(object_))
            assert (later.status, later.json["error"]) == (403, "unauthorized")
            assert all(name.startswith("blob-auth") for name in threads)
            assert relay.permits() == {"global": 0, "sets": 0, "sources": 0, "writers": 0}
    run(main())


def test_late_writer_permit_is_released_once_after_its_waiter_left(tmp_path, monkeypatch):
    async def main():
        async with Relay(tmp_path, handler_seconds=0.3, writer_permits=1) as relay:
            entered, release, _ = pause_after_authorization(relay, monkeypatch, 1)
            gone = asyncio.ensure_future(blob_json(relay.port, "wanted", group=b64(GROUP)))
            assert await asyncio.to_thread(entered.acquire, True, WAIT)
            assert (await gone).status == 0
            assert relay.lane._permits.writers(B_DIGEST) == 1
            busy = await blob_json(relay.port, "wanted", group=b64(GROUP))
            assert (busy.status, busy.json["error"]) == (429, "blobBusy")
            release.set()
            await asyncio.to_thread(relay.lane._auth.submit(lambda: None).result, WAIT)
            for _ in range(5):
                await asyncio.sleep(0)
            assert relay.lane._permits.writers(B_DIGEST) == 0
            assert (await blob_json(relay.port, "wanted", group=b64(GROUP))).status == 200
            assert relay.permits()["sets"] == 0
    run(main())


# Late admission results and cancelled bodies


def pause_store_call(relay, monkeypatch, name, count=None):
    """Pauses `name` after it returned (its resources allocated). With `count`, a semaphore counts entries."""
    original = getattr(relay.store, name)
    entered = threading.Event() if count is None else threading.Semaphore(0)
    release = threading.Event()

    def paused(*args, **kwargs):
        result = original(*args, **kwargs)
        entered.set() if count is None else entered.release()
        assert release.wait(WAIT)
        return result

    monkeypatch.setattr(relay.store, name, paused)
    return entered, release


def record_authorization_threads(relay, monkeypatch):
    store = relay.server.mls.store
    original = store.authorize_active
    threads = []

    def recorded(*args, **kwargs):
        threads.append(threading.current_thread().name)
        return original(*args, **kwargs)

    monkeypatch.setattr(store, "authorize_active", recorded)
    return threads


async def eventually(relay, predicate):
    """Bounded wait for worker threads to finish their own release paths; returns the last ledger."""
    for _ in range(500):
        ledger = await relay.ledger()
        if predicate(ledger) and relay.permits()["sets"] == 0:
            return ledger
        await asyncio.sleep(0.01)
    return ledger


def test_put_admission_result_after_deadline_keeps_its_reservation_until_disposed(tmp_path, monkeypatch):
    async def main():
        async with Relay(tmp_path, handler_seconds=0.3) as relay:
            object_, _, parts = await begin_object(relay, PART_BYTES, b"late put")
            other, _, other_parts = await begin_object(relay, PART_BYTES, b"other put")
            entered, release = pause_store_call(relay, monkeypatch, "admit_put")
            gone = asyncio.ensure_future(put(relay.port, object_, 0, parts[0]))
            assert await asyncio.to_thread(entered.wait, WAIT)
            assert (await gone).status == 0
            ledger = await relay.ledger()
            assert ledger["outstanding"] > 0 and ledger["liveTickets"] == 1
            assert relay.permits()["sets"] == 1 and relay.permits()["writers"] == 1
            relay.store.limits = BlobLimits(max_physical_bytes=ledger["database"] + ledger["outstanding"] + 4096)
            monkeypatch.undo()
            refused = await http(relay.port, f"/v2/mls/blob/put/{b64(GROUP)}/{b64(other)}/0", content_length=PART_BYTES,
                                 send_body=False, content_type="application/octet-stream")
            assert (refused.status, refused.json["error"]) == (507, "blobCapacity")
            release.set()
            ledger = await eventually(relay, lambda value: value["outstanding"] == 0 and value["liveTickets"] == 0)
            assert ledger["outstanding"] == 0 and ledger["liveTickets"] == 0 and relay.permits()["sets"] == 0
            assert (await put(relay.port, other, 0, other_parts[0])).json["stored"] is True
    run(main())


def test_get_admission_result_after_deadline_keeps_its_pin_until_disposed(tmp_path, monkeypatch):
    async def main():
        async with Relay(tmp_path, handler_seconds=0.3) as relay:
            object_, _, parts = await begin_object(relay, 17, b"late get")
            assert (await put(relay.port, object_, 0, parts[0])).json["complete"] is True
            path = next(p for p in (tmp_path / "blobs").rglob("*") if p.is_file() and object_.hex() in p.name)
            entered, release = pause_store_call(relay, monkeypatch, "admit_get")
            gone = asyncio.ensure_future(get(relay.port, object_, 0))
            assert await asyncio.to_thread(entered.wait, WAIT)
            assert (await gone).status == 0
            await asyncio.to_thread(relay.store.release, GROUP, [object_])
            relay.store._clock = lambda: time.time() + 2 * 86400
            report = await asyncio.to_thread(relay.store.expire)
            assert report.deferred == 1 and path.exists()
            assert (await relay.ledger())["pinnedFiles"] == 1
            release.set()
            ledger = await eventually(relay, lambda value: value["pinnedFiles"] == 0 and value["doomed"] == 0)
            assert not path.exists() and ledger["pinnedFiles"] == 0 and ledger["doomed"] == 0
            assert relay.probes[-1].unlinked.count(relay.probes[-1].unlinked[-1]) == 1
            assert relay.permits()["sets"] == 0
    run(main())


def test_short_body_abandons_the_ticket_off_the_loop(tmp_path):
    async def main():
        async with Relay(tmp_path) as relay:
            object_, _, parts = await begin_object(relay, PART_BYTES, b"short")
            reader, writer = await asyncio.open_connection("127.0.0.1", relay.port)
            writer.write((f"POST /v2/mls/blob/put/{b64(GROUP)}/{b64(object_)}/0 HTTP/1.1\r\n"
                          f"Content-Length: {PART_BYTES}\r\nAuthorization: Bearer {b64(B_TOKEN)}\r\n\r\n").encode()
                         + parts[0][:1000])
            await writer.drain()
            for _ in range(200):
                if (await relay.ledger())["liveTickets"] == 1:
                    break
                await asyncio.sleep(0.01)
            writer.close()
            response = Response(await asyncio.wait_for(reader.read(), WAIT))
            assert response.status in (0, 400)
            ledger = await eventually(relay, lambda value: value["outstanding"] == 0 and value["liveTickets"] == 0)
            assert ledger["outstanding"] == 0 and ledger["liveTickets"] == 0 and relay.permits()["sets"] == 0
    run(main())


# The event loop never waits on the blob lock


def test_paused_metadata_commit_does_not_stall_control_or_cancellation(tmp_path):
    async def main():
        async with Relay(tmp_path, store_class=PausedCommitStore, handler_seconds=1.0) as relay:
            object_, _, parts = await begin_object(relay, PART_BYTES, b"commit put")
            other, other_hashes, _ = make_object(17, b"commit begin", route=GROUP)
            reader, writer = await asyncio.open_connection("127.0.0.1", relay.port)
            writer.write((f"POST /v2/mls/blob/put/{b64(GROUP)}/{b64(object_)}/0 HTTP/1.1\r\n"
                          f"Content-Length: {PART_BYTES}\r\nAuthorization: Bearer {b64(B_TOKEN)}\r\n\r\n").encode())
            await writer.drain()
            for _ in range(200):
                if (await relay.ledger())["liveTickets"] == 1:
                    break
                await asyncio.sleep(0.01)
            pause = threading.Event(), threading.Event()
            relay.store.pause = pause
            beginning = asyncio.ensure_future(blob_json(relay.port, "begin", group=b64(GROUP), object=b64(other),
                                                        length=17, parts=[b64(other_hashes[0])]))
            assert await asyncio.to_thread(pause[0].wait, WAIT)
            writer.write(parts[0])
            await writer.drain()
            safety = threading.Timer(5, pause[1].set)
            safety.start()
            beats = []

            async def heartbeat():
                while not pause[1].is_set():
                    beats.append(time.monotonic())
                    await asyncio.sleep(0.05)

            beating = asyncio.ensure_future(heartbeat())
            put_response = Response(await asyncio.wait_for(reader.read(), WAIT))
            assert put_response.status == 0
            appended = await control_append(relay.port, b"control during blob commit")
            assert appended.status == 200 and not pause[1].is_set()
            assert len(beats) >= 5
            pause[1].set()
            safety.cancel()
            await beating
            begin_response = await beginning
            await eventually(relay, lambda value: value["outstanding"] == 0 and value["liveTickets"] == 0)
            committed = await blob_json(relay.port, "manifest", group=b64(GROUP), object=b64(other))
            assert begin_response.status in (0, 200) and committed.status == 200
            ledger = await relay.ledger()
            assert ledger["outstanding"] == 0 and ledger["liveTickets"] == 0 and relay.permits()["sets"] == 0
            present = (await blob_json(relay.port, "manifest", group=b64(GROUP), object=b64(object_))).json["present"]
            assert present in ([], [0])
    run(main())


# Startup and shutdown


def test_startup_failure_closes_everything_and_binds_nothing(tmp_path):
    (tmp_path / "blobs.sqlite3").write_bytes(b"not a database" * 100)

    async def main():
        relay = RelayServer(port=0, metrics_port=0, delivery_port=0, delivery_database_path=tmp_path / "mls.sqlite3",
                            blob=BlobLaneConfig(database=tmp_path / "blobs.sqlite3", directory=tmp_path / "blobs"))
        with pytest.raises(BlobStoreCorrupt):
            await relay.start()
        assert relay._delivery_server is None and relay._websocket_server is None
        with pytest.raises(sqlite3.ProgrammingError):
            relay.mls.store.request("capabilities", {"version": 2})
        assert relay.blob._io._shutdown and relay.blob._control._shutdown
    run(main())


def test_cancelled_startup_closes_the_late_store_off_the_loop(tmp_path):
    entered, release = threading.Event(), threading.Event()
    opened = []

    def slow_open(database, directory, limits):
        entered.set()
        assert release.wait(WAIT)
        store = BlobStore(database, directory, limits=limits)
        opened.append((store, threading.current_thread().name))
        return store

    async def main():
        relay = RelayServer(port=0, metrics_port=0, delivery_port=0, delivery_database_path=tmp_path / "mls.sqlite3",
                            blob=BlobLaneConfig(database=tmp_path / "blobs.sqlite3", directory=tmp_path / "blobs",
                                                open_store=slow_open))
        starting = asyncio.ensure_future(relay.start())
        assert await asyncio.to_thread(entered.wait, WAIT)
        starting.cancel()
        threading.Timer(0.2, release.set).start()
        with pytest.raises(asyncio.CancelledError):
            await starting
        assert relay._delivery_server is None
        store, thread = opened[0]
        assert thread.startswith("blob-io")
        with pytest.raises(sqlite3.ProgrammingError):
            store._db.execute("SELECT 1")
        BlobStore(tmp_path / "blobs.sqlite3", tmp_path / "blobs").close()
    run(main())


@pytest.mark.parametrize("stage", ["auth", "admission", "body", "fsync"])
def test_shutdown_at_each_stage_settles_every_hold(tmp_path, monkeypatch, stage):
    async def main():
        relay = Relay(tmp_path)
        await relay.__aenter__()
        object_, _, parts = await begin_object(relay, PART_BYTES, b"shutdown " + stage.encode())
        events = None
        if stage == "auth":
            entered, release, _ = pause_after_authorization(relay, monkeypatch, 1)
            events = (entered.acquire, release)
        elif stage == "admission":
            entered, release = pause_store_call(relay, monkeypatch, "admit_put")
            events = (entered.wait, release)
        elif stage == "fsync":
            entered, release = relay.probes[-1].pause("sync_file")
            events = (entered.wait, release)
        if stage == "body":
            reader, writer = await asyncio.open_connection("127.0.0.1", relay.port)
            writer.write((f"POST /v2/mls/blob/put/{b64(GROUP)}/{b64(object_)}/0 HTTP/1.1\r\n"
                          f"Content-Length: {PART_BYTES}\r\nAuthorization: Bearer {b64(B_TOKEN)}\r\n\r\n").encode())
            await writer.drain()
            for _ in range(200):
                if (await relay.ledger())["liveTickets"] == 1:
                    break
                await asyncio.sleep(0.01)
        else:
            pending = asyncio.ensure_future(put(relay.port, object_, 0, parts[0]))
            wait, release = events
            assert await asyncio.to_thread(wait, WAIT) is not False
            threading.Timer(0.3, release.set).start()
        store = relay.store
        await relay.server.close()
        assert relay.server.blob_closed is True
        assert relay.lane._permits.snapshot() == {"global": 0, "sets": 0, "sources": 0, "writers": 0}
        with pytest.raises(sqlite3.ProgrammingError):
            store._db.execute("SELECT 1")
        if stage != "body":
            await asyncio.gather(pending, return_exceptions=True)
        reopened = BlobStore(tmp_path / "blobs.sqlite3", tmp_path / "blobs")
        assert reopened.ledger()["outstanding"] == 0
        reopened.close()
    run(main())


def test_leaked_hold_reports_incomplete_close_and_keeps_the_store(tmp_path):
    async def main():
        relay = Relay(tmp_path)
        await relay.__aenter__()
        relay.lane._permits.acquire_request("leak")
        store = relay.store
        await relay.server.close()
        assert relay.server.blob_closed is False and relay.lane.counters["close_incomplete"] == 1
        assert store._db.execute("SELECT 1").fetchone() == (1,)
        store.close()
    run(main())


# Executor outcomes


def test_executor_initializer_failure_answers_busy_without_resources(tmp_path):
    def broken():
        raise OSError("worker initialization failed")

    async def main():
        async with Relay(tmp_path) as relay:
            object_, _, parts = await begin_object(relay, PART_BYTES, b"broken")
            path = f"/v2/mls/blob/put/{b64(GROUP)}/{b64(object_)}/0"
            relay.lane._io = concurrent.futures.ThreadPoolExecutor(1, initializer=broken)
            response = await http(relay.port, path, content_length=PART_BYTES, send_body=False,
                                  content_type="application/octet-stream")
            assert (response.status, response.json["error"]) == (429, "blobBusy")
            assert relay.permits()["sets"] == 0 and (await relay.ledger())["liveTickets"] == 0
            relay.lane._io = concurrent.futures.ThreadPoolExecutor(4, thread_name_prefix="blob-io")
            relay.lane._auth = concurrent.futures.ThreadPoolExecutor(1, initializer=broken)
            response = await http(relay.port, path, content_length=PART_BYTES, send_body=False,
                                  content_type="application/octet-stream")
            assert (response.status, response.json["error"]) == (429, "blobBusy")
            assert relay.permits() == {"global": 0, "sets": 0, "sources": 0, "writers": 0}
            relay.lane._auth = concurrent.futures.ThreadPoolExecutor(2, thread_name_prefix="blob-auth")
            assert (await put(relay.port, object_, 0, parts[0])).json["stored"] is True
    run(main())


def test_ambiguous_admission_submit_runs_the_entered_job_or_none(tmp_path, monkeypatch):
    async def main():
        async with Relay(tmp_path) as relay:
            object_, _, parts = await begin_object(relay, PART_BYTES * 2, b"ambiguous")
            pool = concurrent.futures.ThreadPoolExecutor(2, thread_name_prefix="blob-io")
            blocker_started, blocker_release = threading.Event(), threading.Event()
            pool.submit(lambda: (blocker_started.set(), blocker_release.wait(WAIT)))
            assert await asyncio.to_thread(blocker_started.wait, WAIT)
            relay.lane._io = pool
            original = threading.Thread.start

            def fail_to_start(thread):
                threading.Thread.start = original
                raise RuntimeError("can't start new thread")

            threading.Thread.start = fail_to_start
            try:
                queued = await http(relay.port, f"/v2/mls/blob/put/{b64(GROUP)}/{b64(object_)}/0",
                                    content_length=PART_BYTES, send_body=False, content_type="application/octet-stream")
            finally:
                threading.Thread.start = original
            assert (queued.status, queued.json["error"]) == (429, "blobBusy")
            assert relay.permits()["sets"] == 0
            blocker_release.set()
            await asyncio.to_thread(pool.submit(lambda: None).result, WAIT)
            ledger = await relay.ledger()
            assert ledger["liveTickets"] == 0 and ledger["outstanding"] == 0
            assert (await put(relay.port, object_, 0, parts[0])).json["stored"] is True
    run(main())


# Control dispatcher bounds and attempt gates


class Gate:
    def __init__(self):
        self.entered, self.release = threading.Event(), threading.Event()

    def work(self):
        self.entered.set()
        assert self.release.wait(WAIT)


class CountingExecutor(concurrent.futures.Executor):
    def __init__(self, inner, *, fail=None):
        self.inner, self.fail, self.submits, self.held = inner, fail, 0, []

    def submit(self, fn, /, *args, **kwargs):
        self.submits += 1
        if self.fail is not None:
            mode, self.fail = self.fail, None
            if mode == "hold":
                self.held.append((fn, args))
                raise RuntimeError("submission outcome unknown")
            self.inner.submit(fn, *args, **kwargs)
            if mode == "after-entry":
                assert self.after_entry.wait(WAIT)
            raise RuntimeError("submission outcome unknown")
        return self.inner.submit(fn, *args, **kwargs)


async def settled(dispatcher):
    await dispatcher.idle()
    for _ in range(5):
        await asyncio.sleep(0)


def test_dispatch_queue_and_attempts_stay_bounded_under_a_blocked_worker():
    async def main():
        inner = concurrent.futures.ThreadPoolExecutor(1)
        executor = CountingExecutor(inner)
        dispatcher = ControlDispatcher(executor, asyncio.get_running_loop(), 32)
        blocker = Gate()
        dispatcher.dispatch(blocker.work, True)
        assert await asyncio.to_thread(blocker.entered.wait, WAIT)
        ran = []
        for number in range(3):
            dispatcher.dispatch(lambda number=number: ran.append(number), True)
        submits = executor.submits
        for _ in range(100):
            dispatcher.retry()
        assert executor.submits == submits and dispatcher.snapshot()["credits"] == 4
        for number in range(3, 40):
            dispatcher.dispatch(lambda number=number: ran.append(number), True)
        dispatcher.dispatch(lambda: ran.append("dropped"), False)
        snapshot = dispatcher.snapshot()
        assert snapshot["credits"] == 32 and snapshot["retainedDispatch"] == 9 and snapshot["dropped"] == 1
        submits = executor.submits
        for _ in range(100):
            dispatcher.retry()
        assert executor.submits == submits and dispatcher.snapshot()["credits"] == 32
        blocker.release.set()
        await settled(dispatcher)
        assert dispatcher.snapshot()["retainedDispatch"] == 9
        dispatcher.retry()
        await settled(dispatcher)
        assert sorted(ran) == list(range(40)) and dispatcher.snapshot()["credits"] == 0
        assert dispatcher.snapshot()["entries"] == 0
        inner.shutdown(wait=True)
    run(main())


def test_ambiguous_dispatch_before_entry_fences_the_stale_wrapper_and_keeps_its_credit():
    async def main():
        inner = concurrent.futures.ThreadPoolExecutor(1)
        executor = CountingExecutor(inner, fail="hold")
        dispatcher = ControlDispatcher(executor, asyncio.get_running_loop(), 32)
        ran = []
        dispatcher.dispatch(lambda: ran.append("work"), True)
        snapshot = dispatcher.snapshot()
        assert snapshot["retainedDispatch"] == 1 and snapshot["credits"] == 1 and snapshot["ambiguous_submits"] == 1
        dispatcher.retry()
        await settled(dispatcher)
        assert ran == ["work"] and dispatcher.snapshot()["credits"] == 1
        stale, args = executor.held[0]
        await asyncio.to_thread(inner.submit(stale, *args).result, WAIT)
        await settled(dispatcher)
        assert ran == ["work"] and dispatcher.snapshot()["credits"] == 0
        inner.shutdown(wait=True)
    run(main())


def test_ambiguous_dispatch_after_entry_is_not_overwritten_or_retried():
    async def main():
        inner = concurrent.futures.ThreadPoolExecutor(1)
        executor = CountingExecutor(inner, fail="after-entry")
        executor.after_entry = threading.Event()
        dispatcher = ControlDispatcher(executor, asyncio.get_running_loop(), 32)
        gate = Gate()

        def work():
            executor.after_entry.set()
            gate.work()

        dispatching = asyncio.ensure_future(asyncio.to_thread(dispatcher.dispatch, work, True))
        assert await asyncio.to_thread(gate.entered.wait, WAIT)
        await dispatching
        snapshot = dispatcher.snapshot()
        assert snapshot["retainedDispatch"] == 0 and snapshot.get("ambiguous_submits", 0) == 0
        dispatcher.retry()
        assert executor.submits == 1
        gate.release.set()
        await settled(dispatcher)
        assert dispatcher.snapshot()["credits"] == 0 and dispatcher.snapshot()["entries"] == 0
        inner.shutdown(wait=True)
    run(main())


def test_entered_disposal_failure_is_retained_and_never_retried():
    async def main():
        inner = concurrent.futures.ThreadPoolExecutor(1)
        dispatcher = ControlDispatcher(inner, asyncio.get_running_loop(), 32)
        calls = []

        def failing():
            calls.append(True)
            raise OSError("abandon failed after it started")

        dispatcher.dispatch(failing, True)
        await settled(dispatcher)
        assert dispatcher.retained() == (0, 1)
        for _ in range(10):
            dispatcher.retry()
        await settled(dispatcher)
        assert calls == [True] and dispatcher.retained() == (0, 1) and dispatcher.snapshot()["credits"] == 0
        inner.shutdown(wait=True)
    run(main())


def test_dispatch_cancelled_before_entry_is_retained_for_retry_and_frees_its_credit():
    async def main():
        inner = concurrent.futures.ThreadPoolExecutor(1)
        dispatcher = ControlDispatcher(inner, asyncio.get_running_loop(), 32)
        blocker = Gate()
        dispatcher.dispatch(blocker.work, True)
        assert await asyncio.to_thread(blocker.entered.wait, WAIT)
        ran = []
        dispatcher.dispatch(lambda: ran.append(True), True)
        shutting = asyncio.ensure_future(asyncio.to_thread(inner.shutdown, wait=True, cancel_futures=True))
        await asyncio.sleep(0.05)
        blocker.release.set()
        await shutting
        await settled(dispatcher)
        assert ran == [] and dispatcher.retained() == (1, 0) and dispatcher.snapshot()["credits"] == 0
    run(main())


# Lock discipline


def test_event_loop_never_takes_the_blob_lock(tmp_path, monkeypatch):
    async def main():
        async with Relay(tmp_path, handler_seconds=0.3) as relay:
            loop_thread = threading.get_ident()
            store = relay.store
            acquired = []
            lock = store._lock

            class Recording:
                def __enter__(self):
                    acquired.append(threading.get_ident())
                    return lock.__enter__()

                def __exit__(self, *args):
                    return lock.__exit__(*args)

                def held(self):
                    return lock.held()

            monkeypatch.setattr(store, "_lock", Recording())
            object_, _, parts = await begin_object(relay, PART_BYTES * 2, b"locks")
            reader, writer = await asyncio.open_connection("127.0.0.1", relay.port)
            writer.write((f"POST /v2/mls/blob/put/{b64(GROUP)}/{b64(object_)}/1 HTTP/1.1\r\n"
                          f"Content-Length: {PART_BYTES}\r\nAuthorization: Bearer {b64(B_TOKEN)}\r\n\r\n").encode()
                         + parts[1][:100])
            await writer.drain()
            for _ in range(200):
                if (await relay.ledger())["liveTickets"] == 1:
                    break
                await asyncio.sleep(0.01)
            writer.close()
            assert (await eventually(relay, lambda value: value["liveTickets"] == 0))["liveTickets"] == 0
            assert (await put(relay.port, object_, 0, parts[0])).status == 200
            assert (await get(relay.port, object_, 0)).status == 200
            entered, release = relay.probes[-1].pause("sync_file")
            gone = asyncio.ensure_future(put(relay.port, object_, 1, parts[1]))
            assert await asyncio.to_thread(entered.wait, WAIT)
            assert (await gone).status == 0
            release.set()
            await eventually(relay, lambda value: value["liveTickets"] == 0)
            assert acquired and loop_thread not in acquired
    run(main())


def test_shutdown_under_a_paused_metadata_commit_keeps_the_loop_responsive(tmp_path):
    async def main():
        relay = Relay(tmp_path, store_class=PausedCommitStore)
        await relay.__aenter__()
        object_, hashes, _ = make_object(17, b"shutdown commit", route=GROUP)
        pause = threading.Event(), threading.Event()
        relay.store.pause = pause
        beginning = asyncio.ensure_future(blob_json(relay.port, "begin", group=b64(GROUP), object=b64(object_),
                                                    length=17, parts=[b64(hashes[0])]))
        assert await asyncio.to_thread(pause[0].wait, WAIT)
        closing = asyncio.ensure_future(relay.server.close())
        started = time.monotonic()
        for _ in range(10):
            await asyncio.sleep(0.02)
        assert time.monotonic() - started < 1 and not closing.done()
        pause[1].set()
        await closing
        await asyncio.gather(beginning, return_exceptions=True)
        assert relay.server.blob_closed is True
        reopened = BlobStore(tmp_path / "blobs.sqlite3", tmp_path / "blobs")
        assert reopened.manifest(GROUP, object_)["length"] == 17
        reopened.close()
    run(main())


class Rejecting(concurrent.futures.Executor):
    def __init__(self, inner):
        self.inner, self.reject = inner, True

    def submit(self, fn, /, *args, **kwargs):
        if self.reject:
            raise RuntimeError("cannot schedule new futures")
        return self.inner.submit(fn, *args, **kwargs)


def test_rejected_cancellation_and_settlement_dispatch_preserve_ownership(tmp_path):
    async def main():
        async with Relay(tmp_path, handler_seconds=0.3) as relay:
            object_, _, parts = await begin_object(relay, PART_BYTES, b"rejected")
            dispatcher = relay.lane._dispatcher
            rejecting = Rejecting(dispatcher._executor)
            dispatcher._executor = rejecting
            dispatcher._limit = 1_000
            entered, release = relay.probes[-1].pause("sync_file")
            gone = asyncio.ensure_future(put(relay.port, object_, 0, parts[0]))
            assert await asyncio.to_thread(entered.wait, WAIT)
            assert (await gone).status == 0
            assert dispatcher.snapshot()["dropped"] == 1
            release.set()
            for _ in range(500):
                ledger = await relay.ledger()
                if ledger["liveTickets"] == 0:
                    break
                await asyncio.sleep(0.01)
            assert ledger["committed"] > 0 and ledger["liveTickets"] == 0
            again = await http(relay.port, f"/v2/mls/blob/put/{b64(GROUP)}/{b64(object_)}/0", content_length=PART_BYTES,
                               send_body=False, content_type="application/octet-stream")
            assert again.json["stored"] is True
            ticket = await asyncio.to_thread(relay.store.admit_get, GROUP, object_, 0)
            blocker_started, blocker_release = threading.Event(), threading.Event()
            pool = concurrent.futures.ThreadPoolExecutor(1)
            pool.submit(lambda: (blocker_started.set(), blocker_release.wait(WAIT)))
            assert await asyncio.to_thread(blocker_started.wait, WAIT)
            from gotsync_server.blob import BlobDeadline, run_blob_worker
            with pytest.raises(BlobDeadline):
                await run_blob_worker(relay.store, ticket, lambda: relay.store.get_part(ticket), executor=pool,
                                      timeout=0.05, offload=dispatcher.dispatch)
            assert dispatcher.retained() == (1, 0) and (await relay.ledger())["pinnedFiles"] == 1
            busy = await blob_json(relay.port, "wanted", group=b64(GROUP))
            assert (busy.status, busy.json["error"], busy.headers["retry-after"]) == (429, "blobBusy", "5")
            rejecting.reject = False
            dispatcher.retry()
            await settled(dispatcher)
            assert dispatcher.retained() == (0, 0) and (await relay.ledger())["pinnedFiles"] == 0
            blocker_release.set()
            pool.shutdown(wait=True)
            assert (await blob_json(relay.port, "wanted", group=b64(GROUP))).status == 200
    run(main())


def test_route_header_is_honored_only_from_a_trusted_proxy(tmp_path):
    async def main():
        async with Relay(tmp_path, require_route_header=True) as relay:
            untagged = await blob_json(relay.port, "wanted", group=b64(GROUP))
            assert (untagged.status, untagged.json["error"]) == (404, "notFound")
            spoofed = await http(relay.port, "/v2/mls/blob/wanted",
                                 body=json.dumps({"version": 2, "group": b64(GROUP)}).encode(),
                                 headers={"X-GotSync-Route": "blob"})
            assert (spoofed.status, spoofed.json["error"]) == (404, "notFound")
            relay.server.admission.config = dataclasses.replace(
                relay.server.admission.config, trusted_proxies=(parse_network("127.0.0.1/32"),))
            tagged = await http(relay.port, "/v2/mls/blob/wanted",
                                body=json.dumps({"version": 2, "group": b64(GROUP)}).encode(),
                                headers={"X-GotSync-Route": "blob"})
            assert tagged.status == 200
            control_tag = await http(relay.port, "/v2/mls/blob/wanted",
                                     body=json.dumps({"version": 2, "group": b64(GROUP)}).encode(),
                                     headers={"X-GotSync-Route": "control"})
            assert control_tag.status == 404
    run(main())


class OwnedLock:
    def __init__(self, inner):
        self.inner, self.owner = inner, None

    def acquire(self, blocking=True, timeout=-1):
        acquired = self.inner.acquire(blocking, timeout)
        if acquired:
            self.owner = threading.get_ident()
        return acquired

    def release(self):
        self.owner = None
        self.inner.release()

    def __enter__(self):
        self.acquire()
        return self

    def __exit__(self, *_):
        self.release()


def test_mls_and_blob_locks_are_never_held_together(tmp_path, monkeypatch):
    async def main():
        async with Relay(tmp_path) as relay:
            mls_lock = OwnedLock(relay.server.mls.store._lock)
            monkeypatch.setattr(relay.server.mls.store, "_lock", mls_lock)
            blob_lock = relay.store._lock
            overlaps = []

            class Checking:
                def __enter__(self):
                    overlaps.append(mls_lock.owner == threading.get_ident())
                    return blob_lock.__enter__()

                def __exit__(self, *args):
                    return blob_lock.__exit__(*args)

                def held(self):
                    return blob_lock.held()

            monkeypatch.setattr(relay.store, "_lock", Checking())
            object_, _, parts = await begin_object(relay, 17, b"two locks")
            assert (await put(relay.port, object_, 0, parts[0])).status == 200
            assert (await get(relay.port, object_, 0)).status == 200
            await relay.lane.run_expiry()
            assert overlaps and not any(overlaps)
    run(main())


def test_owned_job_result_delivered_but_not_adopted_is_disposed_once_off_the_loop():
    from gotsync_server.blob import _OwnedHandoff, run_owned_job

    async def main():
        disposed, offloaded, returned = [], [], []
        delayed = []
        original = _OwnedHandoff._deliver

        def hold_delivery(self, result, error):
            delayed.append((self, result, error))

        _OwnedHandoff._deliver = hold_delivery
        try:
            pool = concurrent.futures.ThreadPoolExecutor(1)
            running = asyncio.ensure_future(run_owned_job(
                pool, lambda: "resource", offload=lambda fn, required: offloaded.append((fn, required)),
                timeout=WAIT, dispose=lambda result: disposed.append((result, threading.get_ident())),
                on_return=lambda: returned.append(True)))
            while not delayed:
                await asyncio.sleep(0.01)
            running.cancel()
            with pytest.raises(asyncio.CancelledError):
                await running
        finally:
            _OwnedHandoff._deliver = original
        assert disposed == [] and returned == [] and len(offloaded) == 1 and offloaded[0][1] is True
        await asyncio.to_thread(offloaded[0][0])
        for _ in range(3):
            await asyncio.sleep(0)
        assert [result for result, _ in disposed] == ["resource"] and returned == [True]
        assert disposed[0][1] != threading.get_ident()
        pool.shutdown(wait=True)
    run(main())


def test_owned_job_ambiguous_submit_after_entry_returns_the_real_result():
    from gotsync_server.blob import run_owned_job

    async def main():
        pool = concurrent.futures.ThreadPoolExecutor(2)
        blocker_started, blocker_release = threading.Event(), threading.Event()
        pool.submit(lambda: (blocker_started.set(), blocker_release.wait(WAIT)))
        assert await asyncio.to_thread(blocker_started.wait, WAIT)
        entered, release = threading.Event(), threading.Event()
        returned = []
        original = threading.Thread.start

        def fail_to_start(thread):
            threading.Thread.start = original
            blocker_release.set()
            assert entered.wait(WAIT)
            raise RuntimeError("can't start new thread")

        def job():
            entered.set()
            assert release.wait(WAIT)
            return "committed"

        threading.Thread.start = fail_to_start
        try:
            running = asyncio.ensure_future(run_owned_job(pool, job, offload=lambda fn, required: None, timeout=WAIT,
                                                          on_return=lambda: returned.append(True)))
            await asyncio.sleep(0)
        finally:
            threading.Thread.start = original
        assert returned == []
        release.set()
        assert await running == "committed" and returned == [True]
        pool.shutdown(wait=True)
    run(main())


def test_blob_source_rate_is_separate_and_answers_retry_after(tmp_path):
    from gotsync_server.admission import RateLimit

    async def main():
        async with Relay(tmp_path, source_rate=RateLimit(0.01, 2)) as relay:
            for _ in range(2):
                assert (await blob_json(relay.port, "wanted", group=b64(GROUP))).status == 200
            limited = await blob_json(relay.port, "wanted", group=b64(GROUP))
            assert (limited.status, limited.json["error"]) == (429, "rateLimited")
            assert int(limited.headers["retry-after"]) >= 1
            assert (await control_append(relay.port, b"control is not rate limited by blobs")).status == 200
    run(main())


def test_auth_busy_answers_503_and_expiry_skips_the_cycle(tmp_path):
    async def main():
        async with Relay(tmp_path, auth_lock_seconds=0.2) as relay:
            await begin_object(relay, 17, b"auth busy")
            mls_lock = relay.server.mls.store._lock
            held, release = threading.Event(), threading.Event()

            def hold():
                with mls_lock:
                    held.set()
                    assert release.wait(WAIT)

            holder = threading.Thread(target=hold)
            holder.start()
            assert await asyncio.to_thread(held.wait, WAIT)
            try:
                busy = await blob_json(relay.port, "wanted", group=b64(GROUP))
                assert (busy.status, busy.json["error"], busy.headers["retry-after"]) == (503, "blobAuthBusy", "1")
                await relay.lane.run_expiry()
                assert relay.lane.counters["expiry_auth_busy"] == 1
            finally:
                release.set()
                await asyncio.to_thread(holder.join, WAIT)
            assert relay.permits()["sets"] == 0
            assert (await blob_json(relay.port, "wanted", group=b64(GROUP))).status == 200
    run(main())
