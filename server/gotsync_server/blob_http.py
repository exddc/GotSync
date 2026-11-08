"""Blob HTTP lane: admission, active-writer authorization and the `/v2/mls/blob/` endpoints.

Built only when blobs are enabled. The event loop never takes the blob store lock: request store work runs on
`blob-io`, active-writer authorization on `blob-auth`, and every loop-originated store call (cancellation
requests, unstarted settlements, cleanup disposals, `cancel_all`, state reads) on the one-thread `blob-control`
executor through `ControlDispatcher`.

Lock order: `L_mls` -> `L_permit`. `L_permit` (the permit counters) is a leaf; `L_blob` is never taken with
`L_mls` or `L_permit` held.
"""
from __future__ import annotations

import asyncio
import functools
import math
import re
import threading
from collections import Counter
from collections.abc import Callable, Mapping
from concurrent.futures import BrokenExecutor, Executor, Future, ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .admission import AdmissionController, RateLimit, TokenBucketLimiter
from .blob import (
    BlobBusy, BlobCancelled, BlobDeadline, BlobLimits, BlobStore, BlobTicket, PutResult, run_blob_worker,
    run_owned_job,
)
from .blob_format import ID_BYTES, MAX_OBJECT_BYTES, MAX_PARTS, PART_BYTES
from .http import (
    RequestError, RequestTooLargeError, decode_canonical_base64url, encode_base64url, parse_json_object,
    read_http_exact, write_http_bytes, write_http_response,
)
from .mls import MLSDeliveryStore
from .protocol import PROTOCOL_VERSION

PREFIX = "/v2/mls/blob/"
METADATA_BODY_BYTES = 4096
ROUTE_HEADER = "x-gotsync-route"
_INDEX = re.compile(r"0|[1-9][0-9]?")
_METADATA_FIELDS = {
    "begin": frozenset({"version", "group", "object", "length", "parts"}),
    "manifest": frozenset({"version", "group", "object"}),
    "want": frozenset({"version", "group", "objects"}),
    "wanted": frozenset({"version", "group"}),
    "release": frozenset({"version", "group", "objects"}),
}


class BlobRateLimited(RequestError):
    status = 429
    code = "rateLimited"

    def __init__(self, message: str = "blob rate limited", *, retry_after: float = 1) -> None:
        super().__init__(message)
        self.retry_after = max(1, math.ceil(retry_after))


class BlobAuthBusy(RequestError):
    status = 503
    code = "blobAuthBusy"


class BlobNotFound(RequestError):
    status = 404
    code = "notFound"


class BlobCleanupPending(BlobBusy):
    """New blob work waits while a cleanup entry is retained."""


class BlobRetained(Exception):
    """Dispatched work could not be scheduled and stays owned by its entry."""


def _open_store(database: Path, directory: Path, limits: BlobLimits) -> BlobStore:
    return BlobStore(database, directory, limits=limits)


@dataclass(frozen=True)
class BlobLaneConfig:
    database: Path
    directory: Path
    require_route_header: bool = False
    limits: BlobLimits = field(default_factory=BlobLimits)
    global_permits: int = 8
    source_in_flight: int = 4
    source_rate: RateLimit = RateLimit(8, 32)
    writer_permits: int = 2
    dispatch_attempts: int = 32
    handler_seconds: float = 30.0
    body_seconds: float = 15.0
    metadata_body_seconds: float = 2.0
    auth_lock_seconds: float = 1.0
    expiry_seconds: float = 3600.0
    open_store: Callable[[Path, Path, BlobLimits], BlobStore] = _open_store


class _Permits:
    """Global, per-source and per-writer request permits. `lock` is a leaf: only counter updates run under it."""

    def __init__(self, config: BlobLaneConfig) -> None:
        self.lock = threading.Lock()
        self._config = config
        self.global_in_use = 0
        self.live_sets = 0
        self._sources: dict[str, int] = {}
        self._writers: dict[bytes, int] = {}

    def acquire_request(self, source: str) -> PermitSet:
        with self.lock:
            if self.global_in_use >= self._config.global_permits:
                raise BlobBusy("blob connections busy")
            if self._sources.get(source, 0) >= self._config.source_in_flight:
                raise BlobBusy("blob source busy")
            self.global_in_use += 1
            self._sources[source] = self._sources.get(source, 0) + 1
            self.live_sets += 1
        return PermitSet(self, source)

    def admit_writer(self, digest: bytes) -> None:
        """Called by `authorize_active` under `L_mls`, so a permit is ordered before any removal commit."""
        with self.lock:
            if self._writers.get(digest, 0) >= self._config.writer_permits:
                raise BlobBusy("writer has too many blob requests")
            self._writers[digest] = self._writers.get(digest, 0) + 1

    def release_writer(self, digest: bytes) -> None:
        with self.lock:
            self._release_writer(digest)

    def _release_writer(self, digest: bytes) -> None:
        count = self._writers[digest] - 1
        if count:
            self._writers[digest] = count
        else:
            del self._writers[digest]

    def writers(self, digest: bytes) -> int:
        with self.lock:
            return self._writers.get(digest, 0)

    def snapshot(self) -> dict[str, int]:
        with self.lock:
            return {"global": self.global_in_use, "sets": self.live_sets, "sources": sum(self._sources.values()),
                    "writers": sum(self._writers.values())}


class PermitSet:
    """One request's permits, shared by its handler and every job holding them; freed when the last hold drops."""

    def __init__(self, permits: _Permits, source: str) -> None:
        self._permits = permits
        self._source = source
        self._writer: bytes | None = None
        self._holds = 1

    def hold(self) -> None:
        with self._permits.lock:
            if self._holds <= 0:
                raise RuntimeError("permit set already released")
            self._holds += 1

    def attach_writer(self, digest: bytes) -> None:
        with self._permits.lock:
            self._writer = digest

    def release(self) -> None:
        permits = self._permits
        with permits.lock:
            self._holds -= 1
            if self._holds:
                return
            permits.global_in_use -= 1
            permits.live_sets -= 1
            count = permits._sources[self._source] - 1
            if count:
                permits._sources[self._source] = count
            else:
                del permits._sources[self._source]
            if self._writer is not None:
                permits._release_writer(self._writer)


class _Attempt:
    __slots__ = ("entry", "state")

    def __init__(self, entry: _Entry) -> None:
        self.entry = entry
        self.state = "pending"


class _Entry:
    __slots__ = ("work", "required", "state", "attempt", "claimed", "error", "result", "waiter")

    def __init__(self, work: Callable[[], Any] | None, required: bool) -> None:
        self.work = work
        self.required = required
        self.state = "new"
        self.attempt: _Attempt | None = None
        self.claimed = False
        self.error: BaseException | None = None
        self.result: Any = None
        self.waiter: asyncio.Future[Any] | None = None


class ControlDispatcher:
    """Runs loop-originated store work on the one-thread `blob-control` executor.

    At most `limit` attempts are queued or running, counting stale wrappers that may still sit in the executor
    queue after an ambiguous submit: an attempt's credit returns only when its wrapper returns, or when its
    future is cancelled or failed without running. Each entry has at most one unresolved attempt, a pending ->
    entered/closed gate per attempt, and one claim on its work, so a stale wrapper can never run work a newer
    attempt already started. Required work that cannot be scheduled becomes `retainedDispatch` (retried);
    required work that entered and raised becomes `retainedFailed` (kept, never retried).
    """

    def __init__(self, executor: Executor, loop: asyncio.AbstractEventLoop, limit: int) -> None:
        self._executor = executor
        self._loop = loop
        self._limit = limit
        self._lock = threading.Lock()
        self._credits = 0
        self._entries: set[_Entry] = set()
        self._changed = asyncio.Event()
        self.counters: Counter[str] = Counter()

    def dispatch(self, work: Callable[[], Any], required: bool) -> None:
        entry = _Entry(work, required)
        with self._lock:
            self._entries.add(entry)
        self._schedule(entry)

    async def call(self, work: Callable[[], Any]) -> Any:
        """Runs `work` off the loop and returns its result; raises `BlobRetained` if it cannot be scheduled."""
        entry = _Entry(work, True)
        waiter = entry.waiter = self._loop.create_future()
        with self._lock:
            self._entries.add(entry)
        self._schedule(entry)
        return await asyncio.shield(waiter)

    def retain_failed(self, result: Any, error: BaseException) -> None:
        entry = _Entry(None, True)
        entry.state, entry.result, entry.error, entry.claimed = "retainedFailed", result, error, True
        with self._lock:
            self._entries.add(entry)
            self.counters["retained_failed"] += 1
        self._notify()

    def retry(self) -> None:
        with self._lock:
            pending = [entry for entry in self._entries
                       if entry.state == "retainedDispatch" and entry.attempt is None and not entry.claimed]
        for entry in pending:
            self._schedule(entry)

    def retained(self) -> tuple[int, int]:
        with self._lock:
            return (sum(entry.state == "retainedDispatch" for entry in self._entries),
                    sum(entry.state == "retainedFailed" for entry in self._entries))

    def snapshot(self) -> dict[str, int]:
        dispatch, failed = self.retained()
        with self._lock:
            return {"credits": self._credits, "entries": len(self._entries), "retainedDispatch": dispatch,
                    "retainedFailed": failed, **self.counters}

    async def idle(self) -> None:
        """Waits until no entry is scheduled or running (retained entries may remain)."""
        while True:
            self._changed.clear()
            with self._lock:
                busy = any(entry.state in ("scheduled", "running") for entry in self._entries)
            if not busy:
                return
            await self._changed.wait()

    def _schedule(self, entry: _Entry) -> None:
        with self._lock:
            if entry.attempt is not None or entry.claimed or entry.state not in ("new", "retainedDispatch"):
                return
            if self._credits >= self._limit:
                self._saturated(entry)
                return
            self._credits += 1
            attempt = _Attempt(entry)
            entry.attempt, entry.state = attempt, "scheduled"
        try:
            future = self._executor.submit(self._run, attempt)
        except BaseException:
            with self._lock:
                if attempt.state == "pending":
                    attempt.state = "closed"
                    entry.attempt = None
                    self._not_scheduled(entry)
                    self.counters["ambiguous_submits"] += 1
            self._notify()
            return
        future.add_done_callback(functools.partial(self._finished, attempt))

    def _saturated(self, entry: _Entry) -> None:
        self.counters["saturated"] += 1
        self._not_scheduled(entry)

    def _not_scheduled(self, entry: _Entry) -> None:
        if entry.required:
            entry.state = "retainedDispatch"
            if entry.waiter is not None:
                waiter, entry.waiter = entry.waiter, None
                self._entries.discard(entry)
                self._loop.call_soon_threadsafe(_fail, waiter, BlobRetained())
        else:
            entry.state = "done"
            self._entries.discard(entry)
            self.counters["dropped"] += 1

    def _finished(self, attempt: _Attempt, future: Future[Any]) -> None:
        if not (future.cancelled() or future.exception() is not None):
            return
        with self._lock:
            if attempt.state != "pending":
                return
            attempt.state = "closed"
            self._credits -= 1
            entry = attempt.entry
            if entry.attempt is attempt:
                entry.attempt = None
                self._not_scheduled(entry)
        self._notify()

    def _run(self, attempt: _Attempt) -> None:
        entry = attempt.entry
        with self._lock:
            if attempt.state != "pending" or entry.claimed:
                if attempt.state == "pending":
                    attempt.state = "closed"
                self._credits -= 1
                self._notify()
                return
            attempt.state = "entered"
            entry.claimed, entry.state = True, "running"
            work = entry.work
        result: Any = None
        error: BaseException | None = None
        try:
            result = work()
        except BaseException as caught:
            error = caught
        with self._lock:
            self._credits -= 1
            entry.attempt = None
            entry.work = None
            waiter, entry.waiter = entry.waiter, None
            if error is not None and entry.required and waiter is None:
                entry.state, entry.error = "retainedFailed", error
                self.counters["retained_failed"] += 1
            else:
                entry.state = "done"
                self._entries.discard(entry)
        if waiter is not None:
            self._loop.call_soon_threadsafe(_resolve, waiter, result, error)
        self._notify()

    def _notify(self) -> None:
        try:
            self._loop.call_soon_threadsafe(self._changed.set)
        except RuntimeError:
            pass


def _resolve(waiter: asyncio.Future[Any], result: Any, error: BaseException | None) -> None:
    if waiter.done():
        return
    if error is None:
        waiter.set_result(result)
    else:
        waiter.set_exception(error)


def _fail(waiter: asyncio.Future[Any], error: BaseException) -> None:
    if not waiter.done():
        waiter.set_exception(error)


class BlobLane:
    def __init__(self, config: BlobLaneConfig, *, mls: MLSDeliveryStore, admission: AdmissionController,
                 clock: Callable[[], float]) -> None:
        self.config = config
        self.store: BlobStore | None = None
        self._mls = mls
        self._admission = admission
        self._rate = TokenBucketLimiter(config.source_rate, clock=clock)
        self._permits = _Permits(config)
        self._auth: ThreadPoolExecutor | None = None
        self._io: ThreadPoolExecutor | None = None
        self._control: ThreadPoolExecutor | None = None
        self._dispatcher: ControlDispatcher | None = None
        self._handlers: set[asyncio.Task[Any]] = set()
        self._expiry: asyncio.Task[Any] | None = None
        self._closing = False
        self.counters: Counter[str] = Counter()

    # Lifecycle

    def capabilities(self) -> dict[str, Any]:
        limits = self.config.limits
        return {"blobs": {
            "version": 1, "partBytes": PART_BYTES, "maxObjectBytes": MAX_OBJECT_BYTES, "maxParts": MAX_PARTS,
            "groupQuotaBytes": limits.group_logical_bytes, "retentionSeconds": int(limits.complete_seconds),
            "incompleteSeconds": int(limits.incomplete_seconds),
        }}

    async def start(self) -> None:
        """Creates the executors and opens the store before any listener binds. Cancellation and failure close
        everything already acquired, off the loop; a store that still cannot be closed stays referenced."""
        loop = asyncio.get_running_loop()
        self._auth = ThreadPoolExecutor(2, thread_name_prefix="blob-auth")
        self._io = ThreadPoolExecutor(4, thread_name_prefix="blob-io")
        self._control = ThreadPoolExecutor(1, thread_name_prefix="blob-control")
        self._dispatcher = ControlDispatcher(self._control, loop, self.config.dispatch_attempts)
        config = self.config
        try:
            self.store = await run_owned_job(
                self._io, functools.partial(config.open_store, config.database, config.directory, config.limits),
                offload=self._dispatcher.dispatch, timeout=None, dispose=_close_store,
                retain=self._dispatcher.retain_failed)
        except BaseException:
            self._closing = True
            await asyncio.shield(self._shutdown_executors())
            if any(self._dispatcher.retained()):
                self.counters["start_incomplete"] += 1
            raise
        self._expiry = loop.create_task(self._expire_periodically())

    def is_ready(self) -> bool:
        return self.store is not None and not self._closing and not any(self._dispatcher.retained())

    async def stop_requests(self) -> None:
        """First shutdown phase, right after the listener stops accepting: stop expiry, cancel tickets off the
        loop, and cancel in-flight blob handlers so their jobs depart instead of waiting for request deadlines."""
        if self._closing:
            return
        self._closing = True
        if self._expiry is not None:
            self._expiry.cancel()
            await asyncio.gather(self._expiry, return_exceptions=True)
        if self.store is not None:
            try:
                await self._dispatcher.call(self.store.cancel_all)
            except BlobRetained:
                self.counters["cancel_all_not_scheduled"] += 1
        current = asyncio.current_task()
        handlers = [task for task in self._handlers if task is not current]
        for task in handlers:
            task.cancel()
        await asyncio.gather(*handlers, return_exceptions=True)

    async def close(self) -> bool:
        """Owned shutdown; returns False (and keeps the store handle) when ownership could not be settled."""
        await self.stop_requests()
        state = await self._shutdown_executors()
        for _ in range(100):
            if self._permits.live_sets == 0:
                break
            await asyncio.sleep(0)
        retained = self._dispatcher.retained()
        complete = (self._permits.live_sets == 0 and not any(retained)
                    and state is not None and state["liveTickets"] == 0 and state["pinnedFiles"] == 0)
        if not complete:
            self.counters["close_incomplete"] += 1
            return False
        if self.store is not None:
            await asyncio.to_thread(self.store.close)
        return True

    async def _shutdown_executors(self) -> dict[str, int] | None:
        await asyncio.to_thread(self._auth.shutdown, wait=True, cancel_futures=True)
        await asyncio.to_thread(self._io.shutdown, wait=True, cancel_futures=True)
        self._dispatcher.retry()
        await self._dispatcher.idle()
        state = None
        if self.store is not None:
            try:
                state = await self._dispatcher.call(self.store.ledger)
            except BlobRetained:
                state = None
        await asyncio.to_thread(self._control.shutdown, wait=True)
        return state

    # Expiry

    async def _expire_periodically(self) -> None:
        while True:
            await asyncio.sleep(self.config.expiry_seconds)
            try:
                await self.run_expiry()
            except Exception:
                self.counters["expiry_failed"] += 1

    async def run_expiry(self) -> None:
        """Routes snapshot, then live MLS routes, then expiry of the dead ones: three jobs, no lock held across."""
        dispatch = self._dispatcher.dispatch
        snapshot = await run_owned_job(self._io, self.store.routes, offload=dispatch, timeout=None)
        try:
            live = await run_owned_job(
                self._auth, functools.partial(self._mls.live_routes, snapshot, timeout=self.config.auth_lock_seconds),
                offload=dispatch, timeout=None)
        except TimeoutError:
            self.counters["expiry_auth_busy"] += 1
            return
        dead = [route for route in snapshot if route not in live]
        await run_owned_job(self._io, functools.partial(self.store.expire, dead), offload=dispatch, timeout=None)
        self._dispatcher.retry()

    # Requests

    def classifies(self, target: str) -> bool:
        return target.startswith(PREFIX)

    async def handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter, method: str, target: str,
                     headers: Mapping[str, str], *, control_slot: str | None,
                     release_control: Callable[[str], None]) -> None:
        task = asyncio.current_task()
        self._handlers.add(task)
        permits: PermitSet | None = None
        try:
            try:
                peer = writer.get_extra_info("peername")
                permits = self._admit(method, target, headers, peer)
            finally:
                if control_slot is not None:
                    release_control(control_slot)
            if any(self._dispatcher.retained()):
                self._dispatcher.retry()
                raise BlobCleanupPending("blob cleanup pending")
            deadline = asyncio.get_running_loop().time() + self.config.handler_seconds
            operation, path = _parse_target(target)
            token = _bearer(headers)
            if operation in ("put", "get"):
                await self._binary(operation, path, headers, token, reader, writer, permits, deadline)
            else:
                await self._metadata(operation, headers, token, reader, writer, permits, deadline)
        except BlobDeadline:
            self.counters["deadline"] += 1
        except _Rejected as rejection:
            await _respond(writer, rejection.status, rejection.code, rejection.retry_after)
        except RequestError as error:
            self.counters[f"error_{error.code}"] += 1
            await _respond(writer, error.status, error.code, _retry_after(error))
        finally:
            if permits is not None:
                permits.release()
            self._handlers.discard(task)

    def _admit(self, method: str, target: str, headers: Mapping[str, str], peer: object) -> PermitSet:
        if self._closing or self.store is None:
            raise BlobBusy("blob storage unavailable")
        if method != "POST":
            raise BlobNotFound("unknown blob endpoint")
        _parse_target(target)
        if self.config.require_route_header:
            direct = self._admission.resolve_source(peer, None)
            if not self._admission.is_trusted_proxy(direct.address) or headers.get(ROUTE_HEADER) != "blob":
                raise BlobNotFound("misrouted blob request")
        source = self._admission.resolve_source(peer, headers)
        rejection = self._admission.admit(source, headers)
        if rejection is not None:
            raise _Rejected(rejection.status, rejection.code, rejection.retry_after)
        retry_after = self._rate.acquire(source.key)
        if retry_after is not None:
            raise BlobRateLimited(retry_after=retry_after)
        return self._permits.acquire_request(source.key)

    async def _authorize(self, permits: PermitSet, group: bytes, token: object, deadline: float) -> bytes:
        def authorize() -> bytes:
            try:
                return self._mls.authorize_active(group, token, timeout=self.config.auth_lock_seconds,
                                                  admit=self._permits.admit_writer)
            except TimeoutError as error:
                raise BlobAuthBusy("delivery store busy") from error

        permits.hold()
        try:
            digest = await run_owned_job(
                self._auth, authorize, offload=self._dispatcher.dispatch, timeout=_remaining(deadline),
                dispose=self._permits.release_writer, retain=self._dispatcher.retain_failed,
                on_return=permits.release)
        except (BlobCancelled, BrokenExecutor) as error:
            raise BlobBusy("blob authorization not accepted") from error
        permits.attach_writer(digest)
        return digest

    async def _owned(self, permits: PermitSet, job: Callable[[], Any], deadline: float,
                     dispose: Callable[[Any], None] | None = None) -> Any:
        permits.hold()
        try:
            return await run_owned_job(
                self._io, job, offload=self._dispatcher.dispatch, timeout=_remaining(deadline), dispose=dispose,
                retain=self._dispatcher.retain_failed, on_return=permits.release)
        except (BlobCancelled, BrokenExecutor) as error:
            raise BlobBusy("blob work not accepted") from error

    async def _worker(self, permits: PermitSet, ticket: BlobTicket, work: Callable[[], Any], deadline: float) -> Any:
        permits.hold()
        try:
            return await run_blob_worker(self.store, ticket, work, executor=self._io, timeout=_remaining(deadline),
                                         on_return=permits.release, offload=self._dispatcher.dispatch)
        except (BlobCancelled, BrokenExecutor, RuntimeError) as error:
            raise BlobBusy("blob part worker not accepted") from error

    async def _binary(self, operation: str, path: tuple[bytes, bytes, int], headers: Mapping[str, str],
                      token: object, reader: asyncio.StreamReader, writer: asyncio.StreamWriter, permits: PermitSet,
                      deadline: float) -> None:
        group, object_, index = path
        if "content-encoding" in headers:
            raise RequestError("content encoding is unsupported")
        length = _content_length(headers)
        if operation == "get":
            if length != 0:
                raise RequestError("blob get has no body")
        elif length > PART_BYTES:
            raise RequestTooLargeError("blob part is too large")
        elif length == 0:
            raise RequestError("blob part is empty")
        writer_digest = await self._authorize(permits, group, token, deadline)
        store = self.store
        if operation == "get":
            ticket = await self._owned(permits, functools.partial(store.admit_get, group, object_, index), deadline,
                                       dispose=store.abandon)
            data = await self._worker(permits, ticket, functools.partial(store.get_part, ticket), deadline)
            await write_http_bytes(writer, data)
            return
        admitted = await self._owned(
            permits, functools.partial(store.admit_put, group, object_, index, length, writer=writer_digest),
            deadline, dispose=_abandon_ticket(store))
        if isinstance(admitted, PutResult):
            await _respond_document(writer, {"stored": admitted.stored, "complete": admitted.complete})
            return
        try:
            body = await read_http_exact(reader, length, timeout=min(self.config.body_seconds, _remaining(deadline)))
        except BaseException:
            self._abandon_off_loop(admitted, permits)
            raise
        result = await self._worker(permits, admitted, functools.partial(store.put_part, admitted, body), deadline)
        await _respond_document(writer, {"stored": result.stored, "complete": result.complete})

    def _abandon_off_loop(self, ticket: BlobTicket, permits: PermitSet) -> None:
        permits.hold()
        store = self.store

        def abandon() -> None:
            store.abandon(ticket)
            permits.release()

        self._dispatcher.dispatch(abandon, True)

    async def _metadata(self, operation: str, headers: Mapping[str, str], token: object,
                        reader: asyncio.StreamReader, writer: asyncio.StreamWriter, permits: PermitSet,
                        deadline: float) -> None:
        length = _content_length(headers)
        if length > METADATA_BODY_BYTES:
            raise RequestTooLargeError("blob request is too large")
        body = await read_http_exact(reader, length,
                                     timeout=min(self.config.metadata_body_seconds, _remaining(deadline)))
        if headers.get("content-type", "").split(";", 1)[0].strip().lower() != "application/json":
            raise RequestError("content type must be application/json")
        group, call = _parse_metadata(operation, parse_json_object(body), self.store)
        writer_digest = await self._authorize(permits, group, token, deadline)
        document = await self._owned(permits, functools.partial(call, writer_digest), deadline)
        await _respond_document(writer, document)

    def snapshot(self) -> dict[str, Any]:
        return {"permits": self._permits.snapshot(), "dispatch": self._dispatcher.snapshot(), **self.counters}


class _Rejected(Exception):
    def __init__(self, status: int, code: str, retry_after: int | None) -> None:
        super().__init__(code)
        self.status, self.code, self.retry_after = status, code, retry_after


def _close_store(store: BlobStore) -> None:
    store.close()


def _abandon_ticket(store: BlobStore) -> Callable[[Any], None]:
    def dispose(result: Any) -> None:
        if isinstance(result, BlobTicket):
            store.abandon(result)
    return dispose


def _remaining(deadline: float) -> float:
    remaining = deadline - asyncio.get_running_loop().time()
    if remaining <= 0:
        raise BlobDeadline()
    return remaining


def _identifier(value: object, name: str) -> bytes:
    return decode_canonical_base64url(value, field=name, exact_bytes=ID_BYTES)


def _parse_target(target: str) -> tuple[str, Any]:
    rest = target[len(PREFIX):]
    if rest in _METADATA_FIELDS:
        return rest, None
    parts = rest.split("/")
    if len(parts) == 4 and parts[0] in ("put", "get") and _INDEX.fullmatch(parts[3]) and int(parts[3]) < MAX_PARTS:
        try:
            return parts[0], (_identifier(parts[1], "group"), _identifier(parts[2], "object"), int(parts[3]))
        except RequestError:
            pass
    raise BlobNotFound("unknown blob endpoint")


def _bearer(headers: Mapping[str, str]) -> object:
    scheme, _, token = headers.get("authorization", "").partition(" ")
    return token if scheme.lower() == "bearer" else None


def _content_length(headers: Mapping[str, str]) -> int:
    raw = headers.get("content-length")
    if raw is None or not raw.isdigit() or len(raw) > 10:
        raise RequestError("valid content length is required")
    return int(raw)


def _parse_metadata(operation: str, document: dict[str, Any],
                    store: BlobStore) -> tuple[bytes, Callable[[bytes], dict[str, Any]]]:
    """Validates the whole document before authorization; returns the group and the store call, taking the
    authorized writer digest, to run after it."""
    if set(document) != _METADATA_FIELDS[operation]:
        raise RequestError("unexpected blob request fields")
    if type(document["version"]) is not int or document["version"] != PROTOCOL_VERSION:
        raise RequestError("unsupported blob request version")
    group = _identifier(document["group"], "group")
    if operation in ("begin", "manifest"):
        object_ = _identifier(document["object"], "object")
    if operation in ("want", "release"):
        objects = document["objects"]
        if type(objects) is not list or not 1 <= len(objects) <= 16:
            raise RequestError("invalid objects")
        objects = [_identifier(value, "object") for value in objects]
    if operation == "begin":
        length, parts = document["length"], document["parts"]
        if type(length) is not int or not 1 <= length <= MAX_OBJECT_BYTES:
            raise RequestError("invalid blob length")
        if type(parts) is not list or not 1 <= len(parts) <= MAX_PARTS:
            raise RequestError("invalid part list")
        hashes = [_identifier(value, "part hash") for value in parts]

        def begin(writer: bytes) -> dict[str, Any]:
            return store.begin(group, object_, length, hashes, writer=writer)
        return group, begin
    if operation == "manifest":
        def manifest(writer: bytes) -> dict[str, Any]:
            result = store.manifest(group, object_)
            return {**result, "parts": [encode_base64url(value) for value in result["parts"]]}
        return group, manifest
    if operation == "want":
        return group, lambda writer: {"accepted": store.want(group, objects)}
    if operation == "wanted":
        return group, lambda writer: {"objects": [encode_base64url(value) for value in store.wanted(group)]}

    def release(writer: bytes) -> dict[str, Any]:
        store.release(group, objects)
        return {}
    return group, release


def _retry_after(error: RequestError) -> int | None:
    if isinstance(error, BlobRateLimited):
        return error.retry_after
    if isinstance(error, BlobCleanupPending):
        return 5
    if error.status in (429, 503):
        return 1
    return None


async def _respond(writer: asyncio.StreamWriter, status: int, code: str, retry_after: int | None) -> None:
    await write_http_response(writer, status, {"error": code, "version": PROTOCOL_VERSION},
                              {"Retry-After": str(retry_after)} if retry_after is not None else None)


async def _respond_document(writer: asyncio.StreamWriter, document: dict[str, Any]) -> None:
    await write_http_response(writer, 200, {"version": PROTOCOL_VERSION, **document})
