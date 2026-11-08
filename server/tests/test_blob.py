import asyncio
import concurrent.futures
import errno
import gc
import hashlib
import http
import os
import sqlite3
import subprocess
import sys
import textwrap
import threading
import weakref
from concurrent.futures.thread import BrokenThreadPool
from pathlib import Path

import pytest

from gotsync_server.blob import (
    BlobBusy, BlobCancelled, BlobCapacity, BlobCleanupBacklog, BlobDeadline, BlobFiles, BlobGroupQuota, BlobLimits,
    BlobObjectMissing, BlobPartMismatch, BlobPartMissing, BlobStore, BlobStoreCorrupt, BlobStoreUnsupported,
    PutResult, round_up, run_blob_worker,
)
from gotsync_server.blob_format import PART_BYTES, object_id
from gotsync_server.http import RequestError, encode_base64url
from gotsync_server.mls import MLSDeliveryStore

ROUTE = bytes(range(0x20, 0x40))
OTHER_ROUTE = bytes(range(0x60, 0x80))
WRITER = b"w" * 32
OTHER_WRITER = b"v" * 32
DAY = 86400
WAIT = 10


class Clock:
    def __init__(self, now=1_000_000.0):
        self.now = now

    def __call__(self):
        return self.now


class ProbeFiles(BlobFiles):
    """Records every file operation, and can pause or fail one by name."""

    def __init__(self, directory):
        super().__init__(directory)
        self.calls = []
        self.locked_calls = []
        self.pauses = {}
        self.faults = {}
        self.free = None

    def pause(self, name):
        entered, release = threading.Event(), threading.Event()
        self.pauses[name] = (entered, release)
        return entered, release

    def _hook(self, name):
        self.calls.append(name)
        if self.lock_held():
            self.locked_calls.append(name)
        fault = self.faults.get(name)
        if fault is not None:
            raise fault()
        pause = self.pauses.pop(name, None)
        if pause is not None:
            pause[0].set()
            assert pause[1].wait(WAIT)

    def free_bytes(self):
        return self.free if self.free is not None else super().free_bytes()

    def write_temp(self, name, data):
        self._hook("write_temp")
        super().write_temp(name, data)

    def sync_file(self, descriptor):
        self._hook("sync_file")
        super().sync_file(descriptor)

    def publish(self, temp, route, name):
        self._hook("publish")
        super().publish(temp, route, name)
        self._hook("published")

    def read(self, route, name, size):
        self._hook("read")
        return super().read(route, name, size)

    def unlink(self, file):
        self._hook("unlink")
        super().unlink(file)


def make_object(length, seed=b"", route=ROUTE):
    parts, offset = [], 0
    while offset < length:
        size = min(PART_BYTES, length - offset)
        parts.append((hashlib.sha256(seed + offset.to_bytes(8, "big")).digest() * (size // 32 + 1))[:size])
        offset += size
    hashes = tuple(hashlib.sha256(part).digest() for part in parts)
    return object_id(route, length, hashes), hashes, parts


@pytest.fixture
def harness(tmp_path):
    class Harness:
        def __init__(self):
            self.clock = Clock()
            self.probes = []
            self.store = None

        def open(self, limits=BlobLimits(), files=None):
            def factory(directory):
                probe = (files or ProbeFiles)(directory)
                self.probes.append(probe)
                return probe
            self.store = BlobStore(tmp_path / "blobs.sqlite3", tmp_path / "blobs", limits=limits, clock=self.clock,
                                   files=factory)
            return self.store

        @property
        def files(self):
            return self.probes[-1]

        def stored_files(self):
            root = tmp_path / "blobs"
            return sorted(str(path.relative_to(root)) for path in root.rglob("*") if path.is_file())

        def upload(self, length, seed=b"", route=ROUTE, writer=WRITER, indexes=None):
            store = self.store
            object_, hashes, parts = make_object(length, seed, route)
            store.begin(route, object_, length, hashes, writer=writer)
            result = None
            for index in (range(len(parts)) if indexes is None else indexes):
                ticket = store.admit_put(route, object_, index, len(parts[index]), writer=writer)
                result = ticket if isinstance(ticket, PutResult) else store.put_part(ticket, parts[index])
            return object_, hashes, parts, result

    harness = Harness()
    yield harness
    for probe in harness.probes:
        assert probe.locked_calls == []
    if harness.store is not None:
        try:
            harness.store.close()
        except Exception:
            pass


def test_begin_put_get_and_manifest_round_trip(harness):
    store = harness.open()
    object_, hashes, parts, result = harness.upload(PART_BYTES + 17)
    assert result == PutResult(True, True)
    assert store.manifest(ROUTE, object_) == {"length": PART_BYTES + 17, "parts": hashes, "present": [0, 1],
                                              "complete": True}
    for index, part in enumerate(parts):
        ticket = store.admit_get(ROUTE, object_, index)
        assert store.get_part(ticket) == part
    assert store.usage(ROUTE) == (PART_BYTES + 17, 1, 0)
    assert store.ledger()["committed"] == round_up(PART_BYTES) + round_up(17)
    assert store.ledger()["outstanding"] == 0
    assert len(harness.stored_files()) == 2


def test_begin_is_idempotent_and_identity_immutable(harness):
    store = harness.open()
    object_, hashes, parts = make_object(PART_BYTES * 2)
    assert store.begin(ROUTE, object_, PART_BYTES * 2, hashes, writer=WRITER) == {
        "complete": False, "present": [], "leasedByOther": False}
    assert store.begin(ROUTE, object_, PART_BYTES * 2, hashes, writer=WRITER)["leasedByOther"] is False
    assert store.begin(ROUTE, object_, PART_BYTES * 2, hashes, writer=OTHER_WRITER)["leasedByOther"] is True
    with pytest.raises(RequestError):
        store.begin(ROUTE, object_, PART_BYTES * 2, hashes[::-1], writer=WRITER)
    with pytest.raises(RequestError):
        store.begin(OTHER_ROUTE, object_, PART_BYTES * 2, hashes, writer=WRITER)
    store.put_part(store.admit_put(ROUTE, object_, 1, PART_BYTES, writer=WRITER), parts[1])
    assert store.begin(ROUTE, object_, PART_BYTES * 2, hashes, writer=OTHER_WRITER)["present"] == [1]
    assert store.usage() == (PART_BYTES * 2, 1, 1)
    harness.clock.now += 601
    assert store.begin(ROUTE, object_, PART_BYTES * 2, hashes, writer=OTHER_WRITER)["leasedByOther"] is False


def test_parts_are_verified_and_sized_exactly(harness):
    store = harness.open()
    object_, hashes, parts = make_object(PART_BYTES + 17)
    store.begin(ROUTE, object_, PART_BYTES + 17, hashes, writer=WRITER)
    with pytest.raises(RequestError):
        store.admit_put(ROUTE, object_, 1, 18, writer=WRITER)
    with pytest.raises(RequestError):
        store.admit_put(ROUTE, object_, 2, 17, writer=WRITER)
    with pytest.raises(BlobObjectMissing):
        store.admit_put(ROUTE, b"o" * 32, 0, 17, writer=WRITER)
    ticket = store.admit_put(ROUTE, object_, 1, 17, writer=WRITER)
    with pytest.raises(BlobPartMismatch):
        store.put_part(ticket, b"y" * 17)
    assert "write_temp" not in harness.files.calls
    assert store.ledger()["outstanding"] == 0
    with pytest.raises(BlobPartMissing):
        store.admit_get(ROUTE, object_, 1)
    assert store.put_part(store.admit_put(ROUTE, object_, 1, 17, writer=WRITER), parts[1]) == PutResult(True, False)
    assert store.admit_put(ROUTE, object_, 1, 17, writer=WRITER) == PutResult(True, False)


def test_duplicate_puts_each_reserve_and_one_commits(harness):
    store = harness.open()
    object_, hashes, parts = make_object(PART_BYTES)
    store.begin(ROUTE, object_, PART_BYTES, hashes, writer=WRITER)
    first = store.admit_put(ROUTE, object_, 0, PART_BYTES, writer=WRITER)
    second = store.admit_put(ROUTE, object_, 0, PART_BYTES, writer=OTHER_WRITER)
    assert store.ledger()["outstanding"] == 2 * round_up(PART_BYTES)
    entered, release = harness.files.pause("published")
    with concurrent.futures.ThreadPoolExecutor(2) as pool:
        pending = pool.submit(store.put_part, first, parts[0])
        assert entered.wait(WAIT)
        assert store.ledger()["outstanding"] == 2 * round_up(PART_BYTES)
        assert store.put_part(second, parts[0]) == PutResult(True, True)
        release.set()
        assert pending.result(WAIT) == PutResult(True, True)
    assert store.ledger() | {"database": 0, "journalPeak": 0} == {
        "committed": round_up(PART_BYTES), "doomed": 0, "doomedFiles": 0, "outstanding": 0, "database": 0,
        "journalPeak": 0, "liveTickets": 0}
    assert len(harness.stored_files()) == 1


def test_corrupt_or_missing_part_is_dropped_and_reported_missing(harness, tmp_path):
    store = harness.open()
    object_, hashes, parts, _ = harness.upload(PART_BYTES + 17)
    path = tmp_path / "blobs" / harness.stored_files()[0]
    damaged = bytearray(path.read_bytes())
    damaged[5] ^= 1
    path.write_bytes(bytes(damaged))
    index = int(path.name.split(".")[1])
    with pytest.raises(BlobPartMissing):
        store.get_part(store.admit_get(ROUTE, object_, index))
    assert store.manifest(ROUTE, object_)["present"] == [1 - index]
    assert store.manifest(ROUTE, object_)["complete"] is False
    assert store.usage(ROUTE) == (PART_BYTES + 17, 1, 1)
    assert not path.exists()
    ledger = store.ledger()
    assert ledger["doomed"] == 0 and ledger["committed"] == round_up(len(parts[1 - index]))
    other = tmp_path / "blobs" / harness.stored_files()[0]
    other.unlink()
    with pytest.raises(BlobPartMissing):
        store.get_part(store.admit_get(ROUTE, object_, 1 - index))
    store.put_part(store.admit_put(ROUTE, object_, index, len(parts[index]), writer=WRITER), parts[index])
    assert store.manifest(ROUTE, object_)["present"] == [index]


def test_parallel_last_space_puts_admit_exactly_one(harness):
    store = harness.open()
    objects = [make_object(PART_BYTES, bytes([seed])) for seed in range(6)]
    for number, (object_, hashes, _) in enumerate(objects):
        store.begin(ROUTE, object_, PART_BYTES, hashes, writer=bytes([number]) * 32)
    store.limits = BlobLimits(max_physical_bytes=store.ledger()["database"] + round_up(PART_BYTES) + 4096)
    barrier = threading.Barrier(len(objects))

    def attempt(item):
        barrier.wait(WAIT)
        try:
            return store.admit_put(ROUTE, item[0], 0, PART_BYTES, writer=WRITER)
        except BlobCapacity:
            return None

    with concurrent.futures.ThreadPoolExecutor(len(objects)) as pool:
        tickets = [ticket for ticket in pool.map(attempt, objects) if ticket is not None]
    assert len(tickets) == 1
    assert store.ledger()["outstanding"] == round_up(PART_BYTES)
    store.abandon(tickets[0])
    assert store.ledger()["outstanding"] == 0


def test_parallel_puts_respect_the_disk_reserve(harness):
    store = harness.open(BlobLimits(disk_reserve_bytes=10 * 1024**2))
    objects = [make_object(PART_BYTES, bytes([seed])) for seed in range(5)]
    for number, (object_, hashes, _) in enumerate(objects):
        store.begin(ROUTE, object_, PART_BYTES, hashes, writer=bytes([number]) * 32)
    harness.files.free = 10 * 1024**2 + 2 * round_up(PART_BYTES)
    barrier = threading.Barrier(len(objects))

    def attempt(item):
        barrier.wait(WAIT)
        try:
            return store.admit_put(ROUTE, item[0], 0, PART_BYTES, writer=WRITER)
        except BlobCapacity:
            return None

    with concurrent.futures.ThreadPoolExecutor(len(objects)) as pool:
        tickets = [ticket for ticket in pool.map(attempt, objects) if ticket is not None]
    assert len(tickets) == 2
    for ticket in tickets:
        store.abandon(ticket)


def await_worker(store, ticket, work, *, timeout, interrupt=None):
    """Runs `work` through `run_blob_worker`, interrupts the await, then waits for the worker's return."""
    returned = []

    async def main():
        done = asyncio.Event()

        def on_return():
            returned.append(True)
            done.set()

        with concurrent.futures.ThreadPoolExecutor(1) as pool:
            task = asyncio.ensure_future(
                run_blob_worker(store, ticket, work, executor=pool, timeout=timeout, on_return=on_return))
            if interrupt is not None:
                await interrupt(task)
            with pytest.raises((BlobDeadline, asyncio.CancelledError)):
                await task
            during = store.ledger(), list(returned), ticket.state
            yield_release()
            await asyncio.wait_for(done.wait(), WAIT)
        return during

    yield_release = lambda: None

    def run(release):
        nonlocal yield_release
        yield_release = release
        return asyncio.run(main()), returned

    return run


def test_deadline_before_the_worker_starts_publishes_nothing(harness):
    store = harness.open()
    object_, hashes, parts = make_object(PART_BYTES)
    store.begin(ROUTE, object_, PART_BYTES, hashes, writer=WRITER)
    ticket = store.admit_put(ROUTE, object_, 0, PART_BYTES, writer=WRITER)
    gate = threading.Event()

    def work():
        assert gate.wait(WAIT)
        return store.put_part(ticket, parts[0])

    (during, returned_during, state), returned = await_worker(store, ticket, work, timeout=0.05)(gate.set)
    assert state == "cancelled" and returned_during == []
    assert during["outstanding"] == round_up(PART_BYTES) and during["liveTickets"] == 1
    assert returned == [True]
    assert "write_temp" not in harness.files.calls
    assert store.manifest(ROUTE, object_)["present"] == [] and harness.stored_files() == []
    assert store.ledger()["outstanding"] == 0 and store.ledger()["liveTickets"] == 0


@pytest.mark.parametrize("pause_at", ["published", "sync_file"])
def test_cancelled_request_keeps_ownership_until_the_worker_returns(harness, pause_at):
    store = harness.open()
    object_, hashes, parts = make_object(PART_BYTES)
    store.begin(ROUTE, object_, PART_BYTES, hashes, writer=WRITER)
    ticket = store.admit_put(ROUTE, object_, 0, PART_BYTES, writer=WRITER)
    entered, release = harness.files.pause(pause_at)
    outcome = []

    def work():
        try:
            return store.put_part(ticket, parts[0])
        except BlobCancelled:
            outcome.append("cancelled")
            raise

    async def interrupt(task):
        assert await asyncio.to_thread(entered.wait, WAIT)
        assert harness.stored_files() != [] or pause_at == "sync_file"
        task.cancel()

    (during, returned_during, state), returned = await_worker(
        store, ticket, work, timeout=WAIT, interrupt=interrupt)(release.set)
    assert state == "cancelled" and returned_during == []
    assert during["outstanding"] == round_up(PART_BYTES) and during["liveTickets"] == 1
    assert outcome == ["cancelled"] and returned == [True]
    assert store.manifest(ROUTE, object_)["present"] == []
    assert harness.stored_files() == []
    assert store.ledger()["outstanding"] == 0 and store.ledger()["liveTickets"] == 0
    assert store.ledger()["committed"] == 0


def test_commit_wins_and_a_lost_response_retries_as_stored(harness):
    store = harness.open()
    object_, hashes, parts = make_object(PART_BYTES)
    store.begin(ROUTE, object_, PART_BYTES, hashes, writer=WRITER)
    ticket = store.admit_put(ROUTE, object_, 0, PART_BYTES, writer=WRITER)
    assert store.put_part(ticket, parts[0]) == PutResult(True, True)
    assert store.cancel(ticket) is False
    assert store.admit_put(ROUTE, object_, 0, PART_BYTES, writer=WRITER) == PutResult(True, True)
    assert len(harness.stored_files()) == 1
    assert store.ledger()["outstanding"] == 0


def test_cancel_before_start_and_abandon_release_without_io(harness):
    store = harness.open()
    object_, hashes, parts = make_object(PART_BYTES)
    store.begin(ROUTE, object_, PART_BYTES, hashes, writer=WRITER)
    ticket = store.admit_put(ROUTE, object_, 0, PART_BYTES, writer=WRITER)
    assert store.cancel(ticket) is True
    with pytest.raises(BlobCancelled):
        store.put_part(ticket, parts[0])
    with pytest.raises(RuntimeError):
        store.put_part(ticket, parts[0])
    unused = store.admit_put(ROUTE, object_, 0, PART_BYTES, writer=WRITER)
    store.abandon(unused)
    with pytest.raises(RuntimeError):
        store.abandon(unused)
    assert "write_temp" not in harness.files.calls
    assert store.ledger()["outstanding"] == 0 and store.ledger()["liveTickets"] == 0


def test_enospc_unlinks_and_fails_without_affecting_mls(harness, tmp_path):
    mls = MLSDeliveryStore(tmp_path / "mls.sqlite3")
    group = encode_base64url(b"g" * 32)
    authorization = encode_base64url(b"a" * 32)
    mls.request("create", {"version": 2, "group": group, "authorization": authorization})
    store = harness.open()
    object_, hashes, parts = make_object(PART_BYTES)
    store.begin(ROUTE, object_, PART_BYTES, hashes, writer=WRITER)
    harness.files.faults["sync_file"] = lambda: OSError(errno.ENOSPC, "No space left on device")
    with pytest.raises(BlobCapacity):
        store.put_part(store.admit_put(ROUTE, object_, 0, PART_BYTES, writer=WRITER), parts[0])
    assert harness.stored_files() == []
    assert store.ledger()["outstanding"] == 0 and store.manifest(ROUTE, object_)["present"] == []
    appended = mls.request("append", {"version": 2, "group": group, "authorization": authorization, "epoch": 0,
                                      "kind": "commit", "payload": encode_base64url(b"commit")})
    assert appended["entry"]["cursor"] >= 1
    mls.close()


def test_failure_after_rename_leaves_no_uncounted_file(harness):
    store = harness.open()
    object_, hashes, parts = make_object(PART_BYTES)
    store.begin(ROUTE, object_, PART_BYTES, hashes, writer=WRITER)
    harness.files.faults["published"] = lambda: OSError(errno.EIO, "directory sync failed")
    with pytest.raises(OSError):
        store.put_part(store.admit_put(ROUTE, object_, 0, PART_BYTES, writer=WRITER), parts[0])
    assert harness.stored_files() == []
    assert store.ledger()["outstanding"] == 0 and store.manifest(ROUTE, object_)["present"] == []


def test_failed_unlinks_stay_counted_and_refuse_new_work_until_cleaned(harness):
    store = harness.open(BlobLimits(doomed_max_files=1))
    first, *_ = harness.upload(PART_BYTES + 17, b"a")
    harness.upload(17, b"b")
    harness.files.faults["unlink"] = lambda: PermissionError(errno.EPERM, "unlink refused")
    harness.clock.now += 31 * DAY
    report = store.expire()
    assert (report.objects, report.parts, report.unlinked, report.failed_unlinks) == (2, 3, 0, 3)
    ledger = store.ledger()
    assert ledger["doomed"] == 2 * round_up(17) + round_up(PART_BYTES) and ledger["doomedFiles"] == 3
    assert ledger["committed"] == 0 and len(harness.stored_files()) == 3
    object_, hashes, parts = make_object(17, b"c")
    store.begin(ROUTE, object_, 17, hashes, writer=WRITER)
    with pytest.raises(BlobCleanupBacklog):
        store.admit_put(ROUTE, object_, 0, 17, writer=WRITER)
    del harness.files.faults["unlink"]
    assert store.cleanup() == (3, 0)
    assert store.ledger()["doomed"] == 0 and harness.stored_files() == []
    assert store.put_part(store.admit_put(ROUTE, object_, 0, 17, writer=WRITER), parts[0]) == PutResult(True, True)
    del first


def test_slow_unlink_runs_outside_the_lock_and_keeps_bytes_counted(harness):
    store = harness.open()
    harness.upload(PART_BYTES, b"a")
    harness.clock.now += 31 * DAY
    entered, release = harness.files.pause("unlink")
    with concurrent.futures.ThreadPoolExecutor(1) as pool:
        pending = pool.submit(store.expire)
        assert entered.wait(WAIT)
        assert store.ledger()["doomed"] == round_up(PART_BYTES)
        object_, hashes, _ = make_object(17, b"b")
        assert store.begin(ROUTE, object_, 17, hashes, writer=WRITER)["complete"] is False
        release.set()
        assert pending.result(WAIT).unlinked == 1
    assert store.ledger()["doomed"] == 0


def test_logical_quotas_and_limits_refuse_without_eviction(harness):
    limits = BlobLimits(group_logical_bytes=3 * PART_BYTES, group_objects=3, group_incomplete=2,
                        writer_incomplete=1, global_objects=4)
    store = harness.open(limits)
    harness.upload(PART_BYTES, b"a")
    pending, hashes, _ = make_object(PART_BYTES, b"b")
    store.begin(ROUTE, pending, PART_BYTES, hashes, writer=WRITER)
    blocked, blocked_hashes, _ = make_object(17, b"c")
    with pytest.raises(BlobBusy):
        store.begin(ROUTE, blocked, 17, blocked_hashes, writer=WRITER)
    store.begin(ROUTE, blocked, 17, blocked_hashes, writer=OTHER_WRITER)
    too_many, too_many_hashes, _ = make_object(17, b"d")
    with pytest.raises(BlobGroupQuota):
        store.begin(ROUTE, too_many, 17, too_many_hashes, writer=b"x" * 32)
    big, big_hashes, _ = make_object(2 * PART_BYTES, b"e", OTHER_ROUTE)
    store.begin(OTHER_ROUTE, big, 2 * PART_BYTES, big_hashes, writer=WRITER)
    last, last_hashes, _ = make_object(17, b"f", OTHER_ROUTE)
    with pytest.raises(BlobCapacity):
        store.begin(OTHER_ROUTE, last, 17, last_hashes, writer=OTHER_WRITER)
    assert store.usage(ROUTE) == (2 * PART_BYTES + 17, 3, 2)
    assert store.usage() == (4 * PART_BYTES + 17, 4, 3)
    assert len(harness.stored_files()) == 1


def test_expiry_touch_release_wanted_and_dead_routes(harness):
    store = harness.open()
    complete, *_ = harness.upload(17, b"a")
    incomplete, hashes, parts, _ = harness.upload(PART_BYTES + 17, b"b", indexes=[0])
    released, *_ = harness.upload(17, b"c")
    other, *_ = harness.upload(17, b"d", route=OTHER_ROUTE)
    missing = b"m" * 32
    assert store.want(ROUTE, [incomplete, complete, missing]) == 2
    assert sorted(store.wanted(ROUTE)) == sorted([incomplete, missing])
    store.release(ROUTE, [released])
    harness.clock.now += DAY - 1
    store.get_part(store.admit_get(ROUTE, complete, 0))
    assert store.expire().objects == 0
    harness.clock.now += 2
    report = store.expire()
    assert report.objects == 2 and report.parts == 2 and report.unlinked == 2
    with pytest.raises(BlobObjectMissing):
        store.manifest(ROUTE, incomplete)
    assert store.wanted(ROUTE) == [missing]
    harness.clock.now += 6 * DAY
    store.expire()
    assert store.wanted(ROUTE) == []
    harness.clock.now += 23 * DAY
    assert store.manifest(ROUTE, complete)["complete"] is True
    assert store.expire([OTHER_ROUTE]).objects == 1
    assert store.routes() == [ROUTE]
    harness.clock.now += 2 * DAY
    assert store.expire().objects == 1
    assert store.usage() == (0, 0, 0) and harness.stored_files() == []
    assert store.ledger()["committed"] == 0
    del hashes, parts, other


def test_touch_is_written_at_most_hourly(harness, tmp_path):
    store = harness.open()
    object_, *_ = harness.upload(17)
    harness.clock.now += 1800
    store.get_part(store.admit_get(ROUTE, object_, 0))
    with sqlite3.connect(tmp_path / "blobs.sqlite3") as db:
        assert db.execute("SELECT touched_at FROM blob_objects").fetchone()[0] == harness.clock.now - 1800
    harness.clock.now += 1800
    store.get_part(store.admit_get(ROUTE, object_, 0))
    with sqlite3.connect(tmp_path / "blobs.sqlite3") as db:
        assert db.execute("SELECT touched_at, expires_at FROM blob_objects").fetchone() == (
            harness.clock.now, harness.clock.now + 30 * DAY)


def test_want_and_release_bound_their_inputs(harness):
    store = harness.open(BlobLimits(wanted_per_group=2))
    with pytest.raises(RequestError):
        store.want(ROUTE, [])
    with pytest.raises(RequestError):
        store.want(ROUTE, [b"a" * 32] * 2)
    with pytest.raises(RequestError):
        store.release(ROUTE, [bytes([n]) * 32 for n in range(17)])
    assert store.want(ROUTE, [b"a" * 32, b"b" * 32, b"c" * 32]) == 2
    assert store.want(ROUTE, [b"a" * 32]) == 1


def test_startup_reconciles_files_rows_and_ledgers(harness, tmp_path):
    store = harness.open()
    kept, *_ = harness.upload(PART_BYTES + 17, b"a")
    lost, *_ = harness.upload(17, b"b")
    harness.upload(17, b"c")
    harness.files.faults["unlink"] = lambda: PermissionError(errno.EPERM, "unlink refused")
    store.release(ROUTE, [make_object(17, b"c")[0]])
    harness.clock.now += 2 * DAY
    assert store.expire().failed_unlinks == 1
    store.close()
    root = tmp_path / "blobs"
    files = harness.stored_files()
    lost_file = next(name for name in files if lost.hex() in name)
    (root / lost_file).unlink()
    kept_file = next(name for name in files if kept.hex() + ".1." in name)
    (root / kept_file).write_bytes(b"short")
    (root / "tmp" / ("ab" * 16 + ".part")).write_bytes(b"partial")
    stray = root / ROUTE.hex() / f"{'cd' * 32}.0.{'ef' * 8}"
    stray.write_bytes(b"renamed but never committed")
    (root / "notes.txt").write_text("operator file")
    store = harness.open()
    startup = store.startup
    assert (startup.temporary_removed, startup.orphans_doomed, startup.rows_dropped, startup.doomed_finished) == (
        1, 1, 2, 4)
    assert startup.unexpected == ["notes.txt"]
    assert (store.manifest(ROUTE, kept)["present"], store.manifest(ROUTE, kept)["complete"]) == ([0], False)
    assert store.manifest(ROUTE, lost)["present"] == []
    assert store.usage(ROUTE) == (PART_BYTES + 34, 2, 2)
    expected = round_up(PART_BYTES)
    assert store.ledger()["committed"] == expected and store.ledger()["doomed"] == 0
    assert sorted(harness.stored_files()) == sorted(["notes.txt", next(n for n in files if kept.hex() + ".0." in n)])


class RefuseUnlink(ProbeFiles):
    def __init__(self, directory):
        super().__init__(directory)
        self.faults["unlink"] = lambda: PermissionError(errno.EPERM, "unlink refused")


def test_orphans_that_cannot_be_unlinked_stay_owned_across_restarts(harness, tmp_path):
    store = harness.open()
    store.close()
    route = tmp_path / "blobs" / ROUTE.hex()
    route.mkdir()
    orphan = route / f"{'ab' * 32}.0.{'00' * 8}"
    orphan.write_bytes(b"x" * 17)
    big = route / f"{'cd' * 32}.3.{'11' * 8}"
    big.write_bytes(b"y" * (PART_BYTES + 5000))
    for _ in range(2):
        store = harness.open(files=RefuseUnlink)
        assert store.startup.unexpected == []
        assert store.startup.doomed_finished == 0
        ledger = store.ledger()
        assert (ledger["doomed"], ledger["doomedFiles"]) == (round_up(17) + round_up(PART_BYTES + 5000), 2)
        object_, hashes, parts = make_object(17, b"new")
        store.begin(ROUTE, object_, 17, hashes, writer=WRITER)
        store.limits = BlobLimits(max_physical_bytes=ledger["database"] + ledger["doomed"] + round_up(17) - 1)
        with pytest.raises(BlobCapacity):
            store.admit_put(ROUTE, object_, 0, 17, writer=WRITER)
        store.limits = BlobLimits(doomed_max_files=1)
        with pytest.raises(BlobCleanupBacklog):
            store.admit_put(ROUTE, object_, 0, 17, writer=WRITER)
        store.limits = BlobLimits()
        store.close()
        assert orphan.exists() and big.exists()
        harness.store = None
    store = harness.open()
    assert store.startup.orphans_doomed == 0 and store.startup.doomed_finished == 2
    assert store.ledger()["doomed"] == 0 and not orphan.exists() and not big.exists()
    store.close()
    store = harness.open()
    assert store.startup == type(store.startup)()
    assert store.ledger()["doomed"] == 0


def test_damaged_rows_are_doomed_at_their_actual_size(harness, tmp_path):
    store = harness.open()
    object_, *_ = harness.upload(17, b"grown")
    store.close()
    path = tmp_path / "blobs" / harness.stored_files()[0]
    path.write_bytes(b"z" * (PART_BYTES + 1))
    store = harness.open(files=RefuseUnlink)
    assert store.startup.rows_dropped == 1
    assert store.ledger()["doomed"] == round_up(PART_BYTES + 1) and store.ledger()["committed"] == 0
    store.close()
    store = harness.open()
    assert store.startup.doomed_finished == 1 and not path.exists()
    del object_


def test_canonical_part_paths_that_are_not_files_fail_the_open_unchanged(harness, tmp_path):
    store = harness.open()
    store.close()
    route = tmp_path / "blobs" / ROUTE.hex()
    route.mkdir()
    (route / f"{'ab' * 32}.0.{'00' * 8}").mkdir()
    link = route / f"{'cd' * 32}.0.{'11' * 8}"
    link.symlink_to(tmp_path / "elsewhere")
    before = (tmp_path / "blobs.sqlite3").read_bytes()
    with pytest.raises(BlobStoreCorrupt):
        harness.open()
    assert (tmp_path / "blobs.sqlite3").read_bytes() == before and link.is_symlink()
    (route / f"{'ab' * 32}.0.{'00' * 8}").rmdir()
    store = harness.open()
    assert store.startup.orphans_doomed == 1 and store.startup.doomed_finished == 1 and not link.is_symlink()


def settle_counter():
    calls = []
    return calls, lambda: calls.append(threading.get_ident())


def test_rejected_submission_settles_the_ticket_and_permits_once(harness):
    store = harness.open()
    object_, hashes, parts = make_object(17)
    store.begin(ROUTE, object_, 17, hashes, writer=WRITER)
    ticket = store.admit_put(ROUTE, object_, 0, 17, writer=WRITER)
    pool = concurrent.futures.ThreadPoolExecutor(1)
    pool.shutdown(wait=True)
    calls, on_return = settle_counter()

    async def main():
        with pytest.raises(RuntimeError, match="after shutdown"):
            await run_blob_worker(store, ticket, lambda: store.put_part(ticket, parts[0]), executor=pool, timeout=WAIT,
                                  on_return=on_return)
        assert len(calls) == 1
        await asyncio.sleep(0)

    asyncio.run(main())
    assert len(calls) == 1 and ticket.state == "returned"
    assert store.ledger()["outstanding"] == 0 and store.ledger()["liveTickets"] == 0
    store.close()
    harness.store = None


def test_work_failing_before_the_store_operation_settles_once(harness):
    store = harness.open()
    object_, hashes, parts = make_object(17)
    store.begin(ROUTE, object_, 17, hashes, writer=WRITER)
    ticket = store.admit_put(ROUTE, object_, 0, 17, writer=WRITER)
    calls, on_return = settle_counter()

    def work():
        raise OSError(errno.EIO, "failed before put_part")

    async def main():
        with concurrent.futures.ThreadPoolExecutor(1) as pool:
            with pytest.raises(OSError, match="before put_part"):
                await run_blob_worker(store, ticket, work, executor=pool, timeout=WAIT, on_return=on_return)
        await asyncio.sleep(0)

    asyncio.run(main())
    assert len(calls) == 1 and ticket.state == "returned"
    assert store.ledger()["outstanding"] == 0 and store.ledger()["liveTickets"] == 0
    with pytest.raises(RuntimeError):
        store.put_part(ticket, parts[0])
    assert store.admit_put(ROUTE, object_, 0, 17, writer=WRITER).reservation == round_up(17)


@pytest.mark.parametrize("cancel_by", ["deadline", "shutdown"])
def test_queued_job_cancelled_before_it_runs_settles_immediately(harness, cancel_by):
    store = harness.open()
    object_, hashes, parts = make_object(17)
    store.begin(ROUTE, object_, 17, hashes, writer=WRITER)
    ticket = store.admit_put(ROUTE, object_, 0, 17, writer=WRITER)
    calls, on_return = settle_counter()
    blocker_started, blocker_release = threading.Event(), threading.Event()
    ran = []

    def work():
        ran.append(True)
        return store.put_part(ticket, parts[0])

    async def main():
        pool = concurrent.futures.ThreadPoolExecutor(1)
        blocker = pool.submit(lambda: (blocker_started.set(), blocker_release.wait(WAIT)))
        assert await asyncio.to_thread(blocker_started.wait, WAIT)
        if cancel_by == "deadline":
            with pytest.raises(BlobDeadline):
                await run_blob_worker(store, ticket, work, executor=pool, timeout=0.05, on_return=on_return)
        else:
            task = asyncio.ensure_future(
                run_blob_worker(store, ticket, work, executor=pool, timeout=WAIT, on_return=on_return))
            await asyncio.sleep(0)
            pool.shutdown(wait=False, cancel_futures=True)
            with pytest.raises(BlobCancelled):
                await task
        await asyncio.sleep(0)
        settled = len(calls), store.ledger(), blocker.done()
        blocker_release.set()
        await asyncio.to_thread(pool.shutdown, wait=True)
        return settled

    (count, ledger, blocker_done) = asyncio.run(main())
    assert count == 1 and not blocker_done
    assert ledger["outstanding"] == 0 and ledger["liveTickets"] == 0
    assert ran == [] and len(calls) == 1 and ticket.state == "returned"
    assert "write_temp" not in harness.files.calls


def test_settlement_stays_single_with_a_nonconforming_executor(harness):
    class RunsThenReportsCancelled(concurrent.futures.Executor):
        def submit(self, fn, /, *args, **kwargs):
            try:
                fn(*args, **kwargs)
            except Exception:
                pass
            future = concurrent.futures.Future()
            future.cancel()
            return future

    store = harness.open()
    object_, hashes, parts = make_object(17)
    store.begin(ROUTE, object_, 17, hashes, writer=WRITER)
    ticket = store.admit_put(ROUTE, object_, 0, 17, writer=WRITER)
    calls, on_return = settle_counter()

    async def main():
        assert await run_blob_worker(store, ticket, lambda: store.put_part(ticket, parts[0]),
                                     executor=RunsThenReportsCancelled(), timeout=WAIT,
                                     on_return=on_return) == PutResult(True, True)
        await asyncio.sleep(0)

    asyncio.run(main())
    assert len(calls) == 1 and store.ledger()["outstanding"] == 0 and store.ledger()["liveTickets"] == 0


class PutWork:
    """A weakly referenceable work callable, so tests can prove when its body is released."""

    def __init__(self, store, ticket, body, ran):
        self.store, self.ticket, self.body, self.ran = store, ticket, body, ran

    def __call__(self):
        self.ran.append(True)
        return self.store.put_part(self.ticket, self.body)


def admitted(store, seed=b""):
    object_, hashes, parts = make_object(17, seed)
    store.begin(ROUTE, object_, 17, hashes, writer=WRITER)
    return object_, parts[0], store.admit_put(ROUTE, object_, 0, 17, writer=WRITER)


def test_thread_start_failure_after_enqueue_waits_for_the_running_job(harness):
    store = harness.open()
    object_, body, ticket = admitted(store)
    entered, release = harness.files.pause("sync_file")
    released = []
    blocker_started, blocker_release = threading.Event(), threading.Event()
    original = threading.Thread.start

    def fail_to_start(thread):
        threading.Thread.start = original
        blocker_release.set()
        assert entered.wait(WAIT)
        raise RuntimeError("can't start new thread")

    async def main():
        pool = concurrent.futures.ThreadPoolExecutor(2)
        pool.submit(lambda: (blocker_started.set(), blocker_release.wait(WAIT)))
        assert await asyncio.to_thread(blocker_started.wait, WAIT)
        threading.Thread.start = fail_to_start
        try:
            task = asyncio.ensure_future(run_blob_worker(
                store, ticket, lambda: store.put_part(ticket, body), executor=pool, timeout=WAIT,
                on_return=lambda: released.append(store.manifest(ROUTE, object_)["present"])))
            for _ in range(5):
                await asyncio.sleep(0)
        finally:
            threading.Thread.start = original
        during = list(released), store.ledger(), ticket.state, task.done()
        release.set()
        result = await task
        await asyncio.sleep(0)
        await asyncio.to_thread(pool.shutdown, wait=True)
        return during, result

    (during_released, during_ledger, state, done), result = asyncio.run(main())
    assert during_released == [] and state == "running" and not done
    assert during_ledger["outstanding"] == round_up(17) and during_ledger["liveTickets"] == 1
    assert result == PutResult(True, True)
    assert released == [[0]]
    assert store.ledger()["outstanding"] == 0 and store.ledger()["liveTickets"] == 0


def test_thread_start_failure_with_the_job_still_queued_settles_once(harness):
    store = harness.open()
    object_, body, ticket = admitted(store)
    calls, on_return = settle_counter()
    ran = []
    blocker_started, blocker_release = threading.Event(), threading.Event()
    original = threading.Thread.start

    def fail_to_start(thread):
        threading.Thread.start = original
        raise RuntimeError("can't start new thread")

    async def main():
        pool = concurrent.futures.ThreadPoolExecutor(2)
        pool.submit(lambda: (blocker_started.set(), blocker_release.wait(WAIT)))
        assert await asyncio.to_thread(blocker_started.wait, WAIT)
        work = PutWork(store, ticket, body, ran)
        reference = weakref.ref(work)
        pending = run_blob_worker(store, ticket, work, executor=pool, timeout=WAIT, on_return=on_return)
        del work
        threading.Thread.start = fail_to_start
        try:
            with pytest.raises(RuntimeError, match="can't start new thread"):
                await pending
        finally:
            threading.Thread.start = original
        del pending
        gc.collect()
        during = reference() is None, len(calls), store.ledger()
        blocker_release.set()
        await asyncio.to_thread(pool.shutdown, wait=True)
        await asyncio.sleep(0)
        return during

    body_released, settled_calls, ledger = asyncio.run(main())
    assert body_released and settled_calls == 1
    assert ledger["outstanding"] == 0 and ledger["liveTickets"] == 0
    assert ran == [] and len(calls) == 1 and ticket.state == "returned"
    assert "write_temp" not in harness.files.calls
    del object_


def test_initializer_failure_settles_the_unentered_job(harness):
    store = harness.open()
    _, body, ticket = admitted(store)
    calls, on_return = settle_counter()
    ran = []

    def initializer():
        raise OSError("worker initialization failed")

    async def main():
        pool = concurrent.futures.ThreadPoolExecutor(1, initializer=initializer)
        with pytest.raises(BrokenThreadPool):
            await run_blob_worker(store, ticket, PutWork(store, ticket, body, ran), executor=pool, timeout=WAIT,
                                  on_return=on_return)
        await asyncio.sleep(0)
        await asyncio.to_thread(pool.shutdown, wait=True)

    asyncio.run(main())
    assert ran == [] and len(calls) == 1 and ticket.state == "returned"
    assert store.ledger()["outstanding"] == 0 and store.ledger()["liveTickets"] == 0
    store.close()
    harness.store = None


@pytest.mark.parametrize("schedule", ["entered", "queued-deadline", "rejected-submission"])
def test_failing_on_return_never_blocks_delivery_or_repeats(harness, schedule):
    store = harness.open()
    _, body, ticket = admitted(store)
    calls = []
    reported = []

    def on_return():
        calls.append(True)
        raise ValueError("permit release failed")

    async def main():
        asyncio.get_running_loop().set_exception_handler(lambda loop, context: reported.append(context["exception"]))
        pool = concurrent.futures.ThreadPoolExecutor(1)
        release = threading.Event()
        if schedule == "entered":
            outcome = await run_blob_worker(store, ticket, lambda: store.put_part(ticket, body), executor=pool,
                                            timeout=WAIT, on_return=on_return)
        elif schedule == "queued-deadline":
            pool.submit(release.wait, WAIT)
            with pytest.raises(BlobDeadline):
                await run_blob_worker(store, ticket, lambda: store.put_part(ticket, body), executor=pool,
                                      timeout=0.05, on_return=on_return)
            outcome = "deadline"
        else:
            pool.shutdown(wait=True)
            with pytest.raises(RuntimeError, match="after shutdown"):
                await run_blob_worker(store, ticket, lambda: store.put_part(ticket, body), executor=pool,
                                      timeout=WAIT, on_return=on_return)
            outcome = "rejected"
        for _ in range(3):
            await asyncio.sleep(0)
        release.set()
        await asyncio.to_thread(pool.shutdown, wait=True)
        return outcome

    outcome = asyncio.run(main())
    assert outcome == {"entered": PutResult(True, True), "queued-deadline": "deadline",
                       "rejected-submission": "rejected"}[schedule]
    assert len(calls) == 1 and [type(error) for error in reported] == [ValueError]
    assert store.ledger()["outstanding"] == 0 and store.ledger()["liveTickets"] == 0


def test_grown_doomed_entry_is_recounted_at_startup(harness, tmp_path):
    store = harness.open()
    store.close()
    route = tmp_path / "blobs" / ROUTE.hex()
    route.mkdir()
    orphan = route / f"{'ab' * 32}.0.{'00' * 8}"
    orphan.write_bytes(b"x" * 17)
    store = harness.open(files=RefuseUnlink)
    assert store.ledger()["doomed"] == round_up(17)
    store.close()
    orphan.write_bytes(b"y" * (PART_BYTES + 1))
    store = harness.open(files=RefuseUnlink)
    ledger = store.ledger()
    assert (ledger["doomed"], ledger["doomedFiles"]) == (round_up(PART_BYTES + 1), 1)
    object_, hashes, _ = make_object(17, b"new")
    store.begin(ROUTE, object_, 17, hashes, writer=WRITER)
    store.limits = BlobLimits(max_physical_bytes=ledger["database"] + ledger["doomed"] + round_up(17) - 1)
    with pytest.raises(BlobCapacity):
        store.admit_put(ROUTE, object_, 0, 17, writer=WRITER)
    store.close()
    store = harness.open()
    assert store.startup.doomed_finished == 1 and store.ledger()["doomed"] == 0 and not orphan.exists()


@pytest.mark.parametrize("where", ["route", "tmp"])
def test_doomed_special_entry_fails_the_open_unchanged(harness, tmp_path, where):
    store = harness.open()
    store.close()
    if where == "route":
        doomed = f"{ROUTE.hex()}/{'ab' * 32}.0.{'00' * 8}"
    else:
        doomed = f"tmp/{'ab' * 16}.part"
    with sqlite3.connect(tmp_path / "blobs.sqlite3", isolation_level=None) as db:
        db.execute("INSERT INTO blob_doomed VALUES (?, 17)", (doomed,))
    db.close()
    special = tmp_path / "blobs" / doomed
    special.mkdir(parents=True)
    leftover = tmp_path / "blobs" / "tmp" / f"{'cd' * 16}.part"
    leftover.write_bytes(b"partial")
    before = (tmp_path / "blobs.sqlite3").read_bytes()
    with pytest.raises(BlobStoreCorrupt):
        harness.open()
    assert (tmp_path / "blobs.sqlite3").read_bytes() == before
    assert special.is_dir() and leftover.read_bytes() == b"partial"
    special.rmdir()
    store = harness.open()
    assert store.startup.temporary_removed == 1 and store.startup.doomed_finished == 1
    assert store.ledger()["doomed"] == 0 and not leftover.exists()


def test_cancelled_get_keeps_retention_and_permits_until_return(harness, tmp_path):
    store = harness.open()
    object_, *_ = harness.upload(17, b"get")
    store.release(ROUTE, [object_])

    def retention():
        with sqlite3.connect(tmp_path / "blobs.sqlite3") as db:
            return db.execute("SELECT touched_at, expires_at, released FROM blob_objects").fetchone()

    before = retention()
    harness.clock.now += 3600
    ticket = store.admit_get(ROUTE, object_, 0)
    entered, release = harness.files.pause("read")
    outcome = []

    def work():
        try:
            return store.get_part(ticket)
        except BlobCancelled:
            outcome.append("cancelled")
            raise

    async def interrupt(task):
        assert await asyncio.to_thread(entered.wait, WAIT)
        task.cancel()

    (during, returned_during, state), returned = await_worker(
        store, ticket, work, timeout=WAIT, interrupt=interrupt)(release.set)
    assert state == "cancelled" and returned_during == [] and during["liveTickets"] == 1
    assert outcome == ["cancelled"] and returned == [True] and ticket.state == "returned"
    assert retention() == before and store.ledger()["liveTickets"] == 0

    async def normal():
        with concurrent.futures.ThreadPoolExecutor(1) as pool:
            fresh = store.admit_get(ROUTE, object_, 0)
            return await run_blob_worker(store, fresh, lambda: store.get_part(fresh), executor=pool, timeout=WAIT)

    assert len(asyncio.run(normal())) == 17
    assert retention() == (harness.clock.now, harness.clock.now + 30 * DAY, 0)


def child(tmp_path, body):
    script = textwrap.dedent(f"""
        import hashlib, os, sys
        sys.path.insert(0, {str(Path(__file__).resolve().parents[1])!r})
        sys.path.insert(0, {str(Path(__file__).resolve().parent)!r})
        from test_blob import ProbeFiles, make_object, ROUTE, WRITER
        from gotsync_server.blob import BlobStore
        from gotsync_server.blob_format import PART_BYTES

        class Crash(ProbeFiles):
            point = os.environ["CRASH_AT"]
            def _hook(self, name):
                if name == self.point:
                    os._exit(17)

        store = BlobStore({str(tmp_path / "blobs.sqlite3")!r}, {str(tmp_path / "blobs")!r}, files=Crash)
    """) + textwrap.dedent(body)
    return script


@pytest.mark.parametrize("point,rows,files", [("sync_file", 0, 0), ("published", 0, 0), ("never", 1, 1)])
def test_process_crash_points_reconcile_on_restart(tmp_path, point, rows, files):
    script = child(tmp_path, """
        object_, hashes, parts = make_object(PART_BYTES, b"crash")
        store.begin(ROUTE, object_, PART_BYTES, hashes, writer=WRITER)
        store.put_part(store.admit_put(ROUTE, object_, 0, PART_BYTES, writer=WRITER), parts[0])
        os._exit(0)
    """)
    result = subprocess.run([sys.executable, "-c", script], env={**os.environ, "CRASH_AT": point}, timeout=60)
    assert result.returncode == (0 if point == "never" else 17)
    store = BlobStore(tmp_path / "blobs.sqlite3", tmp_path / "blobs")
    object_, _, parts = make_object(PART_BYTES, b"crash")
    assert len(store.manifest(ROUTE, object_)["present"]) == rows
    assert len([path for path in (tmp_path / "blobs").rglob("*") if path.is_file()]) == files
    assert store.ledger()["committed"] == rows * round_up(PART_BYTES)
    retry = store.admit_put(ROUTE, object_, 0, PART_BYTES, writer=WRITER)
    if rows:
        assert retry == PutResult(True, True)
    else:
        assert store.put_part(retry, parts[0]) == PutResult(True, True)
    store.close()


def test_crash_after_dooming_finishes_unlinks_at_startup(tmp_path):
    script = child(tmp_path, """
        object_, hashes, parts = make_object(17, b"doomed")
        store.begin(ROUTE, object_, 17, hashes, writer=WRITER)
        store.put_part(store.admit_put(ROUTE, object_, 0, 17, writer=WRITER), parts[0])
        store.release(ROUTE, [object_])
        store._clock = lambda: 10**10
        store.expire()
    """)
    result = subprocess.run([sys.executable, "-c", script], env={**os.environ, "CRASH_AT": "unlink"}, timeout=60)
    assert result.returncode == 17
    with sqlite3.connect(tmp_path / "blobs.sqlite3") as db:
        assert db.execute("SELECT COUNT(*) FROM blob_doomed").fetchone()[0] == 1
    store = BlobStore(tmp_path / "blobs.sqlite3", tmp_path / "blobs")
    assert store.startup.doomed_finished == 1
    assert store.ledger()["doomed"] == 0 and store.usage() == (0, 0, 0)
    assert [path for path in (tmp_path / "blobs").rglob("*") if path.is_file()] == []
    store.close()


def test_hot_rollback_journal_is_recovered_not_converted(tmp_path):
    store = BlobStore(tmp_path / "blobs.sqlite3", tmp_path / "blobs")
    object_, hashes, _ = make_object(17, b"journal")
    store.begin(ROUTE, object_, 17, hashes, writer=WRITER)
    store.close()
    script = textwrap.dedent(f"""
        import os, sqlite3
        db = sqlite3.connect({str(tmp_path / "blobs.sqlite3")!r}, isolation_level=None)
        db.execute("PRAGMA cache_size=1")
        db.execute("BEGIN IMMEDIATE")
        db.execute("DELETE FROM blob_usage")
        db.execute("UPDATE blob_objects SET length=1")
        for n in range(2000):
            db.execute("INSERT INTO blob_wanted VALUES (?, ?, 0)", (os.urandom(32), os.urandom(32)))
        os._exit(9)
    """)
    assert subprocess.run([sys.executable, "-c", script], timeout=60).returncode == 9
    assert Path(f"{tmp_path / 'blobs.sqlite3'}-journal").stat().st_size > 0
    store = BlobStore(tmp_path / "blobs.sqlite3", tmp_path / "blobs")
    assert store.startup.recovered_journal is True
    assert store.usage() == (17, 1, 1)
    assert store.wanted(ROUTE) == []
    store.close()


@pytest.mark.parametrize("tamper,error", [
    ("PRAGMA user_version=2", BlobStoreUnsupported),
    ("PRAGMA application_id=7", BlobStoreUnsupported),
    ("PRAGMA journal_mode=WAL", BlobStoreUnsupported),
    ("CREATE TABLE extra(x INTEGER)", BlobStoreCorrupt),
    ("UPDATE blob_usage SET objects=objects+1", BlobStoreCorrupt),
    ("UPDATE blob_objects SET complete=1", BlobStoreCorrupt),
    ("UPDATE blob_objects SET part_hashes=zeroblob(32)", BlobStoreCorrupt),
])
def test_rejected_databases_are_preserved(tmp_path, tamper, error):
    store = BlobStore(tmp_path / "blobs.sqlite3", tmp_path / "blobs")
    object_, hashes, _ = make_object(PART_BYTES + 17, b"keep")
    store.begin(ROUTE, object_, PART_BYTES + 17, hashes, writer=WRITER)
    store.close()
    with sqlite3.connect(tmp_path / "blobs.sqlite3", isolation_level=None) as db:
        db.execute(tamper)
    db.close()
    before = (tmp_path / "blobs.sqlite3").read_bytes()
    with pytest.raises(error):
        BlobStore(tmp_path / "blobs.sqlite3", tmp_path / "blobs")
    assert (tmp_path / "blobs.sqlite3").read_bytes() == before
    assert not Path(f"{tmp_path / 'blobs.sqlite3'}-wal").exists() or "WAL" in tamper


@pytest.mark.parametrize("contents", [b"", b"not a database" * 100])
def test_foreign_files_are_never_converted(tmp_path, contents):
    path = tmp_path / "blobs.sqlite3"
    path.write_bytes(contents)
    with pytest.raises((BlobStoreUnsupported, BlobStoreCorrupt)):
        BlobStore(path, tmp_path / "blobs")
    assert path.read_bytes() == contents


def test_symlinked_paths_are_refused(tmp_path):
    (tmp_path / "real").mkdir()
    (tmp_path / "linked").symlink_to(tmp_path / "real")
    with pytest.raises(BlobStoreUnsupported):
        BlobStore(tmp_path / "blobs.sqlite3", tmp_path / "linked")
    (tmp_path / "target.sqlite3").write_bytes(b"")
    (tmp_path / "db-link.sqlite3").symlink_to(tmp_path / "target.sqlite3")
    with pytest.raises(BlobStoreUnsupported):
        BlobStore(tmp_path / "db-link.sqlite3", tmp_path / "blobs")
    store = BlobStore(tmp_path / "blobs.sqlite3", tmp_path / "blobs")
    object_, hashes, parts = make_object(17, b"link")
    store.begin(ROUTE, object_, 17, hashes, writer=WRITER)
    store.close()
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "victim").write_bytes(b"keep")
    (tmp_path / "blobs" / ROUTE.hex()).symlink_to(outside)
    store = BlobStore(tmp_path / "blobs.sqlite3", tmp_path / "blobs")
    assert store.startup.unexpected == [ROUTE.hex()]
    with pytest.raises(OSError):
        store.put_part(store.admit_put(ROUTE, object_, 0, 17, writer=WRITER), parts[0])
    assert (outside / "victim").read_bytes() == b"keep" and len(list(outside.iterdir())) == 1
    assert store.ledger()["outstanding"] == 0
    store.close()


def test_expiry_batches_bound_the_rollback_journal(harness, tmp_path):
    store = harness.open()
    store.close()
    with sqlite3.connect(tmp_path / "blobs.sqlite3", isolation_level=None) as db:
        db.execute("BEGIN")
        length = 20 * PART_BYTES
        for number in range(3 * 64):
            hashes = tuple(hashlib.sha256(bytes([number % 256, number // 256, index])).digest() for index in range(20))
            object_ = object_id(ROUTE, length, hashes)
            db.execute("INSERT INTO blob_objects VALUES (?, ?, ?, 20, ?, 1, 0, 0, 0, 0, NULL, NULL, ?)",
                       (ROUTE, object_, length, b"".join(hashes), WRITER))
            for index in range(20):
                name = f"{ROUTE.hex()}/{object_.hex()}.{index}.{number:016x}"
                db.execute("INSERT INTO blob_parts VALUES (?, ?, ?, ?, ?, 0)", (ROUTE, object_, index, name, PART_BYTES))
                path = tmp_path / "blobs" / name
                path.parent.mkdir(exist_ok=True)
                with open(path, "wb") as sparse:
                    sparse.truncate(PART_BYTES)
        db.execute("UPDATE blob_usage SET logical_bytes=?, objects=?, incomplete=0", (3 * 64 * length, 3 * 64))
        db.execute("INSERT INTO blob_usage VALUES (?, ?, ?, 0)", (ROUTE, 3 * 64 * length, 3 * 64))
        db.execute("COMMIT")
    store = harness.open()
    deletes, per_transaction = [0], []

    def trace(statement):
        if statement.startswith("DELETE FROM blob_objects"):
            deletes[0] += 1
        elif statement == "COMMIT":
            per_transaction.append(deletes[0])
            deletes[0] = 0

    store._db.set_trace_callback(trace)
    report = store.expire()
    store._db.set_trace_callback(None)
    assert (report.objects, report.parts, report.unlinked) == (192, 3840, 3840)
    assert max(per_transaction) == store.limits.expiry_batch
    peak = store.ledger()["journalPeak"]
    assert 0 < peak <= store.limits.metadata_allowance_bytes
    print(f"journal peak {peak} bytes, database {(tmp_path / 'blobs.sqlite3').stat().st_size} bytes")


def test_every_error_status_is_an_http_status():
    for error in (BlobObjectMissing, BlobPartMissing, BlobPartMismatch, BlobBusy, BlobGroupQuota, BlobCapacity,
                  BlobCleanupBacklog):
        assert http.HTTPStatus(error.status)
        assert error().body()["error"] == error.code


def test_importing_and_constructing_limits_opens_nothing(tmp_path):
    script = textwrap.dedent(f"""
        import sys, threading
        sys.path.insert(0, {str(Path(__file__).resolve().parents[1])!r})
        import gotsync_server
        assert "gotsync_server.blob" not in sys.modules
        import gotsync_server.blob as blob
        blob.BlobLimits()
        assert threading.active_count() == 1
    """)
    subprocess.run([sys.executable, "-c", script], cwd=tmp_path, check=True, timeout=60)
    assert list(tmp_path.iterdir()) == []
