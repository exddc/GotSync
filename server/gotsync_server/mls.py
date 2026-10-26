"""Opaque MLS delivery service."""
from __future__ import annotations

import asyncio
import hashlib
import math
import os
import sqlite3
import stat
import threading
import time
from pathlib import Path
from typing import Any, NamedTuple

from .http import (
    RequestError,
    UnsupportedVersion,
    legacy_target_error,
    decode_canonical_base64url,
    encode_base64url,
    parse_json_object,
    read_http_json_request,
    write_http_response,
)
from .protocol import PROTOCOL_VERSION as VERSION

MAX_PAYLOAD = 448 * 1024
MAX_ENTRIES = 10_000
MAX_BYTES = 16 * 1024 * 1024
DEFAULT_MAX_PACKAGES = 4096
DEFAULT_MAX_GROUPS = 4096
DEFAULT_RETENTION_SECONDS = 90 * 86400
GRACE_SECONDS = 86400
PACKAGE_LIFETIME_SECONDS = 900
ACTIVITY_RESOLUTION_SECONDS = 3600
EXPIRY_INTERVAL_SECONDS = 3600
ADDED_COLUMNS = (
    ("mls_groups", "expired", "INTEGER", 0),
    ("mls_groups", "active_at", "REAL", None),
    ("mls_entries", "created_at", "REAL", None),
    ("mls_rejections", "created_at", "REAL", None),
)


class DeliveryConflict(RequestError):
    status = 409
    code = "epochConflict"


class DeliveryCapacity(RequestError):
    status = 429
    code = "deliveryCapacity"


class DeliveryUnauthorized(RequestError):
    status = 403
    code = "unauthorized"


class HistoryExpired(RequestError):
    status = 410
    code = "historyExpired"


def blob(doc: dict, name: str, size: int | None = None, maximum: int = MAX_PAYLOAD) -> bytes:
    result = decode_canonical_base64url(doc.get(name), field=name, exact_bytes=size, maximum_bytes=maximum)
    if not result:
        raise RequestError(f"{name} must not be empty")
    return result


def number(doc: dict, name: str, default: int | None = None) -> int:
    result = doc.get(name, default)
    if type(result) is not int or not 0 <= result < 2**53:
        raise RequestError(f"invalid {name}")
    return result


class Writer(NamedTuple):
    digest: bytes
    ack: int
    removal: int | None
    expired: int


class MLSDeliveryStore:
    def __init__(
        self, path: str | os.PathLike[str], *, max_groups: int = DEFAULT_MAX_GROUPS,
        max_packages: int = DEFAULT_MAX_PACKAGES, retention_seconds: float = DEFAULT_RETENTION_SECONDS,
    ) -> None:
        if type(max_groups) is not int or type(max_packages) is not int or min(max_groups, max_packages) <= 0:
            raise ValueError("directory limits must be positive integers")
        if not GRACE_SECONDS <= retention_seconds < math.inf:
            raise ValueError("retention must be at least one day")
        self.max_groups = max_groups
        self.max_packages = max_packages
        self.retention_seconds = retention_seconds
        self._lock = threading.Lock()
        path = Path(path)
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.close(os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600))
        if not stat.S_ISREG(os.lstat(path).st_mode):
            raise ValueError("delivery database path must be a regular file")
        path.chmod(0o600)
        self._db = sqlite3.connect(path, check_same_thread=False)
        self._db.execute("PRAGMA synchronous=FULL")
        self._db.execute("PRAGMA secure_delete=ON")
        self._db.execute("PRAGMA journal_mode=DELETE")
        self._db.executescript("""
            CREATE TABLE IF NOT EXISTS mls_groups (
                route BLOB PRIMARY KEY, epoch INTEGER NOT NULL, head INTEGER NOT NULL DEFAULT 0,
                expired INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL, active_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS mls_writers (
                route BLOB NOT NULL, digest BLOB NOT NULL, ack INTEGER NOT NULL DEFAULT 0,
                removal INTEGER, removed_at REAL, PRIMARY KEY(route, digest)
            );
            CREATE TABLE IF NOT EXISTS mls_entries (
                cursor INTEGER PRIMARY KEY AUTOINCREMENT, route BLOB NOT NULL,
                epoch INTEGER NOT NULL, kind TEXT NOT NULL, payload BLOB NOT NULL,
                welcome BLOB, package BLOB, removed_writer BLOB, added_writer BLOB,
                created_at REAL NOT NULL, UNIQUE(route, payload)
            );
            CREATE INDEX IF NOT EXISTS mls_route_cursor ON mls_entries(route, cursor);
            CREATE TABLE IF NOT EXISTS mls_rejections (
                route BLOB NOT NULL, digest BLOB NOT NULL, epoch INTEGER NOT NULL, created_at REAL NOT NULL,
                PRIMARY KEY(route, digest)
            );
            CREATE TABLE IF NOT EXISTS mls_packages (
                reference BLOB PRIMARY KEY, payload BLOB, expires REAL NOT NULL, writer BLOB NOT NULL, pairing BLOB NOT NULL
            );
        """)
        for table, column, kind, default in ADDED_COLUMNS:
            if column not in {row[1] for row in self._db.execute(f"PRAGMA table_info({table})")}:
                self._db.execute(f"ALTER TABLE {table} ADD COLUMN {column} {kind} NOT NULL DEFAULT {default if default is not None else time.time()}")
        self._db.execute("CREATE INDEX IF NOT EXISTS mls_entry_age ON mls_entries(created_at)")
        self._db.commit()

    def close(self) -> None:
        self._db.close()

    def is_ready(self, *, max_wait_seconds: float = 0.25) -> bool:
        deadline = time.monotonic() + max_wait_seconds
        if not self._lock.acquire(timeout=max_wait_seconds):
            return False
        original_busy_timeout: int | None = None
        try:
            original_busy_timeout = int(self._db.execute("PRAGMA busy_timeout").fetchone()[0])
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return False
            self._db.execute(f"PRAGMA busy_timeout = {max(1, math.ceil(remaining * 1000))}")
            self._db.execute("BEGIN IMMEDIATE")
            self._db.execute("ROLLBACK")
            return True
        except sqlite3.Error:
            return False
        finally:
            if original_busy_timeout is not None:
                try:
                    self._db.execute(f"PRAGMA busy_timeout = {original_busy_timeout}")
                except sqlite3.Error:
                    pass
            self._lock.release()

    def request(self, operation: str, document: dict[str, Any]) -> dict[str, Any]:
        if type(document.get("version")) is not int or document["version"] != VERSION:
            raise UnsupportedVersion(f"MLS delivery requires protocol version {VERSION}; pair every device again")
        with self._lock:
            self._expire_committed()
            with self._db:
                return {"version": VERSION, **self._request(operation, document)}

    def expire(self) -> None:
        with self._lock:
            self._expire_committed()

    def _expire_committed(self) -> None:
        with self._db:
            self._expire(time.time())

    def _request(self, operation: str, doc: dict[str, Any]) -> dict[str, Any]:
        operations = {
            "key-package/publish": self._publish, "key-package/fetch": self._package_fetch,
            "create": self._create, "fetch": self._fetch, "ack": self._ack, "append": self._append,
        }
        handler = operations.get(operation)
        if handler is None:
            raise RequestError("unknown MLS operation")
        return handler(doc)

    def _publish(self, doc: dict) -> dict:
        package = blob(doc, "payload", maximum=65536)
        writer = hashlib.sha256(blob(doc, "authorization", 32)).digest()
        pairing = blob(doc, "pairingHash", 32)
        reference = hashlib.sha256(package).digest()
        existing = self._db.execute("SELECT writer,pairing FROM mls_packages WHERE reference=?", (reference,)).fetchone()
        if existing and existing != (writer, pairing):
            raise DeliveryConflict("package publisher differs")
        if not existing:
            if self._db.execute("SELECT COUNT(*) FROM mls_packages").fetchone()[0] >= self.max_packages:
                raise DeliveryCapacity("package directory full")
            self._db.execute("INSERT INTO mls_packages VALUES (?,?,?,?,?)", (reference, package, time.time() + PACKAGE_LIFETIME_SECONDS, writer, pairing))
        return {"reference": encode_base64url(reference)}

    def _package_fetch(self, doc: dict) -> dict:
        reference = blob(doc, "reference", 32)
        try:
            pairing = hashlib.sha256(blob(doc, "pairingToken", 32)).digest()
        except RequestError as error:
            raise DeliveryUnauthorized("pairing token required") from error
        row = self._db.execute("SELECT payload,pairing FROM mls_packages WHERE reference=?", (reference,)).fetchone()
        if row and row[1] != pairing:
            raise DeliveryUnauthorized("invalid pairing token")
        self._db.execute("UPDATE mls_packages SET payload=NULL WHERE reference=?", (reference,))
        return {"payload": encode_base64url(row[0]) if row and row[0] else None}

    def _create(self, doc: dict) -> dict:
        route = blob(doc, "group", 32)
        writer = hashlib.sha256(blob(doc, "authorization", 32)).digest()
        if self._db.execute("SELECT 1 FROM mls_groups WHERE route=?", (route,)).fetchone():
            if not self._db.execute("SELECT 1 FROM mls_writers WHERE route=? AND digest=? AND removal IS NULL", (route, writer)).fetchone():
                raise DeliveryConflict("group already registered")
        else:
            if self._db.execute("SELECT COUNT(*) FROM mls_groups").fetchone()[0] >= self.max_groups:
                raise DeliveryCapacity("group directory full")
            now = time.time()
            self._db.execute("INSERT INTO mls_groups(route,epoch,created_at,active_at) VALUES (?,0,?,?)", (route, now, now))
            self._db.execute("INSERT INTO mls_writers(route,digest) VALUES (?,?)", (route, writer))
        return {}

    def _authorize(self, doc: dict, route: bytes, *, writing: bool = False) -> Writer:
        try:
            digest = hashlib.sha256(blob(doc, "authorization", 32)).digest()
        except RequestError as error:
            raise DeliveryUnauthorized("writer token required") from error
        group = self._db.execute("SELECT expired FROM mls_groups WHERE route=?", (route,)).fetchone()
        if group is None:
            raise HistoryExpired("group expired")
        row = self._db.execute("SELECT ack,removal,removed_at FROM mls_writers WHERE route=? AND digest=?", (route, digest)).fetchone()
        now = time.time()
        if row is None or (row[1] is not None and (writing or row[0] >= row[1] or now >= row[2] + GRACE_SECONDS)):
            raise DeliveryUnauthorized("writer not authorized")
        self._db.execute("UPDATE mls_groups SET active_at=? WHERE route=? AND active_at<?", (now, route, now - ACTIVITY_RESOLUTION_SECONDS))
        return Writer(digest, row[0], row[1], group[0])

    def _fetch(self, doc: dict) -> dict:
        route = blob(doc, "group", 32)
        writer = self._authorize(doc, route)
        after = number(doc, "after")
        limit = number(doc, "limit", default=16)
        if not 1 <= limit <= 32:
            raise RequestError("invalid limit")
        if max(writer.ack, after) < writer.expired:
            raise HistoryExpired("unread entries expired")
        rows = self._db.execute(
            "SELECT cursor,epoch,kind,payload,welcome,package,removed_writer,added_writer FROM mls_entries WHERE route=? AND cursor>? AND cursor<=? ORDER BY cursor LIMIT ?",
            (route, after, writer.removal if writer.removal is not None else 2**53, limit),
        ).fetchall()
        return {"entries": [self._entry(row) for row in rows]}

    def _ack(self, doc: dict) -> dict:
        route = blob(doc, "route", 32)
        writer = self._authorize(doc, route)
        cursor = number(doc, "cursor")
        head = self._db.execute("SELECT head FROM mls_groups WHERE route=?", (route,)).fetchone()[0]
        if cursor > head or (writer.removal is not None and cursor > writer.removal):
            raise RequestError("cursor exceeds readable log")
        self._db.execute("UPDATE mls_writers SET ack=MAX(ack,?) WHERE route=? AND digest=?", (cursor, route, writer.digest))
        self._prune(time.time())
        return {}

    def _expire(self, now: float) -> None:
        cutoff = now - self.retention_seconds
        self._db.execute("DELETE FROM mls_packages WHERE expires <= ?", (now,))
        self._db.execute(
            "UPDATE mls_groups SET expired=(SELECT MAX(cursor) FROM mls_entries WHERE route=mls_groups.route AND created_at<=?) "
            "WHERE route IN (SELECT route FROM mls_entries WHERE created_at<=?)",
            (cutoff, cutoff),
        )
        self._db.execute("DELETE FROM mls_entries WHERE created_at<=?", (cutoff,))
        self._db.execute("DELETE FROM mls_rejections WHERE created_at<=?", (now - GRACE_SECONDS,))
        self._db.execute("DELETE FROM mls_writers WHERE removed_at<=?", (now - GRACE_SECONDS,))
        stale = self._db.execute(
            "SELECT route FROM mls_groups WHERE active_at<=? OR (head=0 AND created_at<=?)",
            (cutoff - ACTIVITY_RESOLUTION_SECONDS, now - GRACE_SECONDS),
        ).fetchall()
        for table in ("mls_entries", "mls_writers", "mls_rejections", "mls_groups"):
            self._db.executemany(f"DELETE FROM {table} WHERE route=?", stale)
        self._prune(now)

    def _prune(self, now: float) -> None:
        self._db.execute(
            "DELETE FROM mls_entries WHERE cursor <= (SELECT MIN(ack) FROM mls_writers WHERE mls_writers.route=mls_entries.route AND (removal IS NULL OR (ack<removal AND removed_at>?)))",
            (now - GRACE_SECONDS,),
        )

    def _append(self, doc: dict) -> dict:
        route = blob(doc, "group", 32)
        writer = self._authorize(doc, route, writing=True).digest
        entry = self._parse_entry(doc, writer)
        duplicate = self._db.execute(
            "SELECT cursor,epoch,kind,payload,welcome,package,removed_writer,added_writer FROM mls_entries WHERE route=? AND payload=?", (route, entry[2])
        ).fetchone()
        if duplicate:
            if entry != duplicate[1:]:
                raise DeliveryConflict("retry differs from accepted message")
            return {"entry": self._entry(duplicate)}
        digest = hashlib.sha256(entry[2]).digest()
        rejected = self._db.execute("SELECT epoch FROM mls_rejections WHERE route=? AND digest=?", (route, digest)).fetchone()
        if rejected:
            return {"error": "keyPackageUnavailable", "epoch": rejected[0]}
        current = self._db.execute("SELECT epoch FROM mls_groups WHERE route=?", (route,)).fetchone()
        if current is None or entry[0] != current[0]:
            raise DeliveryConflict("refetch the winning commit")
        if not self._check_membership(route, entry):
            if self._db.execute("SELECT COUNT(*) FROM mls_rejections WHERE route=?", (route,)).fetchone()[0] >= MAX_ENTRIES:
                raise DeliveryCapacity("rejection journal full")
            self._db.execute("INSERT INTO mls_rejections VALUES (?,?,?,?)", (route, digest, entry[0], time.time()))
            return {"error": "keyPackageUnavailable", "epoch": entry[0]}
        return self._accept_entry(route, entry, writer)

    def _parse_entry(self, doc: dict, writer: bytes) -> tuple:
        epoch = number(doc, "epoch")
        kind = doc.get("kind")
        if kind not in ("commit", "application", "proposal"):
            raise RequestError("invalid kind")
        payload = blob(doc, "payload")
        welcome = blob(doc, "welcome") if doc.get("welcome") is not None else None
        package = blob(doc, "reference", 32) if doc.get("reference") is not None else None
        removed_writer = blob(doc, "removeWriter", 32) if doc.get("removeWriter") is not None else None
        added_writer = blob(doc, "addWriter", 32) if doc.get("addWriter") is not None else None
        if removed_writer is not None and (kind != "commit" or removed_writer == writer):
            raise RequestError("invalid writer removal")
        if (welcome is None) != (package is None) or (welcome is None) != (added_writer is None) or (welcome is not None and kind != "commit"):
            raise RequestError("Welcome requires commit and KeyPackage reference")
        if kind == "proposal" and removed_writer is not None:
            raise RequestError("a proposal can only remove its sender")
        return epoch, kind, payload, welcome, package, removed_writer, added_writer

    def _check_membership(self, route: bytes, entry: tuple) -> bool:
        _, _, _, _, package, _, added_writer = entry
        joining = self._db.execute("SELECT writer FROM mls_packages WHERE reference=?", (package,)).fetchone() if package else None
        if package and (not joining or joining[0] != added_writer):
            return False
        if joining and not self._db.execute("SELECT 1 FROM mls_writers WHERE route=? AND digest=? AND removal IS NULL", (route, added_writer)).fetchone():
            if self._db.execute("SELECT COUNT(*) FROM mls_writers WHERE route=? AND removal IS NULL", (route,)).fetchone()[0] >= 8:
                raise DeliveryCapacity("writer directory full")
        return True

    def _accept_entry(self, route: bytes, entry: tuple, writer: bytes) -> dict:
        epoch, kind, payload, welcome, package, removed_writer, added_writer = entry
        count, size = self._db.execute(
            "SELECT COUNT(*),COALESCE(SUM(LENGTH(payload)+COALESCE(LENGTH(welcome),0)+COALESCE(LENGTH(package),0)),0) FROM mls_entries WHERE route=?", (route,)
        ).fetchone()
        if count >= MAX_ENTRIES or size + len(payload) + len(welcome or b"") + len(package or b"") > MAX_BYTES:
            raise DeliveryCapacity("delivery log full")
        cursor = self._db.execute(
            "INSERT INTO mls_entries(route,epoch,kind,payload,welcome,package,removed_writer,added_writer,created_at) VALUES (?,?,?,?,?,?,?,?,?)",
            (route, *entry, time.time()),
        ).lastrowid
        self._db.execute("UPDATE mls_groups SET head=?,epoch=epoch+? WHERE route=?", (cursor, int(kind == "commit"), route))
        if package:
            self._db.execute("INSERT OR REPLACE INTO mls_writers(route,digest,ack) VALUES (?,?,?)", (route, added_writer, cursor - 1))
            self._db.execute("DELETE FROM mls_packages WHERE reference=?", (package,))
        for removed in (removed_writer, writer if kind == "proposal" else None):
            if removed:
                self._db.execute("UPDATE mls_writers SET removal=?,removed_at=? WHERE route=? AND digest=? AND removal IS NULL", (cursor, time.time(), route, removed))
        return {"entry": self._entry((cursor, *entry))}

    @staticmethod
    def _entry(row: tuple) -> dict[str, Any]:
        cursor, epoch, kind, payload, welcome, package, removed_writer, added_writer = row
        return {"cursor": cursor, "epoch": epoch, "kind": kind, "payload": encode_base64url(payload),
                "welcome": encode_base64url(welcome) if welcome else None,
                "reference": encode_base64url(package) if package else None,
                "removeWriter": encode_base64url(removed_writer) if removed_writer else None,
                "addWriter": encode_base64url(added_writer) if added_writer else None}


class MLSDeliveryServer:
    def __init__(self, store: MLSDeliveryStore) -> None:
        self.store = store
        self._server: asyncio.Server | None = None
        self._tasks: set[asyncio.Task] = set()
        self._expiry: asyncio.Task | None = None

    def start_expiry(self, interval: float = EXPIRY_INTERVAL_SECONDS) -> None:
        self._expiry = asyncio.create_task(self._expire_periodically(interval))

    async def stop_expiry(self) -> None:
        if self._expiry:
            self._expiry.cancel()
            await asyncio.gather(self._expiry, return_exceptions=True)
            self._expiry = None

    async def _expire_periodically(self, interval: float) -> None:
        while True:
            await asyncio.sleep(interval)
            try:
                await asyncio.to_thread(self.store.expire)
            except sqlite3.Error:
                pass

    async def start(self) -> int:
        self._server = await asyncio.start_server(self._accept, "127.0.0.1", 0, limit=8192)
        self.start_expiry()
        return self._server.sockets[0].getsockname()[1]

    async def close(self) -> None:
        await self.stop_expiry()
        if self._server:
            self._server.close()
            await self._server.wait_closed()
        if self._tasks:
            await asyncio.gather(*self._tasks, return_exceptions=True)
        self.store.close()

    def _accept(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        if len(self._tasks) >= 32:
            writer.close()
            return
        task = asyncio.create_task(self._handle(reader, writer))
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    async def _handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        try:
            method, target, headers, body = await read_http_json_request(reader, maximum_body_bytes=1024 * 1024)
            if (legacy := legacy_target_error(target)) is not None:
                raise legacy
            if method != "POST" or not target.startswith("/v2/mls/"):
                await write_http_response(writer, 404, {"error": "notFound", "version": VERSION})
                return
            await self.handle_request(target, headers, body, writer)
        except RequestError as error:
            await write_http_response(writer, error.status, error.body())
        except (ConnectionError, asyncio.IncompleteReadError):
            pass
        except Exception:
            try:
                await write_http_response(writer, 500, {"error": "internalError", "version": VERSION})
            except ConnectionError:
                pass
        finally:
            writer.close()
            try:
                await writer.wait_closed()
            except ConnectionError:
                pass

    async def handle_request(self, target: str, headers: dict, body: bytes, writer: asyncio.StreamWriter) -> None:
        try:
            if headers.get("content-type", "").split(";", 1)[0].strip().lower() != "application/json":
                raise RequestError("content type must be application/json")
            document = parse_json_object(body)
            document.pop("authorization", None)
            authorization = headers.get("authorization", "")
            scheme, _, token = authorization.partition(" ")
            if scheme.lower() == "bearer":
                document["authorization"] = token
            result = await asyncio.to_thread(self.store.request, target.removeprefix("/v2/mls/"), document)
            await write_http_response(writer, 409 if "error" in result else 200, result)
        except RequestError as error:
            await write_http_response(writer, error.status, error.body())
        except ConnectionError:
            raise
        except Exception:
            await write_http_response(writer, 500, {"error": "internalError", "version": VERSION})
