"""Opaque MLS delivery service."""
from __future__ import annotations

import asyncio
import hashlib
import sqlite3
import threading
import time
from pathlib import Path
from typing import Any

from .mailbox import MailboxError, decode_canonical_base64url, encode_base64url
from .server import read_http_json_request, parse_mailbox_json, write_http_response

VERSION = 2
MAX_PAYLOAD = 448 * 1024
MAX_ENTRIES = 10_000
MAX_BYTES = 16 * 1024 * 1024
MAX_PACKAGES = 128
MAX_GROUPS = 128


class DeliveryConflict(MailboxError):
    status = 409
    code = "epochConflict"


class DeliveryCapacity(MailboxError):
    status = 429
    code = "deliveryCapacity"


class DeliveryUnauthorized(MailboxError):
    status = 403
    code = "unauthorized"


def blob(doc: dict, name: str, size: int | None = None, maximum: int = MAX_PAYLOAD) -> bytes:
    result = decode_canonical_base64url(doc.get(name), field=name, exact_bytes=size, maximum_bytes=maximum)
    if not result:
        raise MailboxError(f"{name} must not be empty")
    return result


def number(doc: dict, name: str) -> int:
    result = doc.get(name)
    if type(result) is not int or not 0 <= result < 2**53:
        raise MailboxError(f"invalid {name}")
    return result


class MLSDeliveryStore:
    def __init__(self, path: Path) -> None:
        self._lock = threading.Lock()
        self._db = sqlite3.connect(path, check_same_thread=False)
        self._db.execute("PRAGMA synchronous=FULL")
        self._db.executescript("""
            CREATE TABLE IF NOT EXISTS mls_groups (route BLOB PRIMARY KEY, epoch INTEGER NOT NULL, head INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS mls_writers (
                route BLOB NOT NULL, digest BLOB NOT NULL, ack INTEGER NOT NULL DEFAULT 0,
                removal INTEGER, removed_at REAL, PRIMARY KEY(route, digest)
            );
            CREATE TABLE IF NOT EXISTS mls_entries (
                cursor INTEGER PRIMARY KEY AUTOINCREMENT, route BLOB NOT NULL,
                epoch INTEGER NOT NULL, kind TEXT NOT NULL, payload BLOB NOT NULL,
                welcome BLOB, package BLOB, removed_writer BLOB, added_writer BLOB,
                UNIQUE(route, payload)
            );
            CREATE INDEX IF NOT EXISTS mls_route_cursor ON mls_entries(route, cursor);
            CREATE TABLE IF NOT EXISTS mls_rejections (
                route BLOB NOT NULL, digest BLOB NOT NULL, epoch INTEGER NOT NULL,
                PRIMARY KEY(route, digest)
            );
            CREATE TABLE IF NOT EXISTS mls_packages (
                reference BLOB PRIMARY KEY, payload BLOB, expires REAL NOT NULL, writer BLOB NOT NULL, pairing BLOB NOT NULL
            );
        """)
        self._db.commit()

    def close(self) -> None:
        self._db.close()

    def request(self, operation: str, document: dict[str, Any]) -> dict[str, Any]:
        if type(document.get("version")) is not int or document["version"] != VERSION:
            raise MailboxError("unsupported version")
        with self._lock, self._db:
            self._db.execute("DELETE FROM mls_packages WHERE expires <= ?", (time.time(),))
            self._prune()
            result = self._request(operation, document)
            return {"version": VERSION, **result}

    def _request(self, operation: str, doc: dict[str, Any]) -> dict[str, Any]:
        operations = {
            "key-package/publish": self._publish, "key-package/fetch": self._package_fetch,
            "create": self._create, "fetch": self._fetch, "ack": self._ack, "append": self._append,
        }
        handler = operations.get(operation)
        if handler is None:
            raise MailboxError("unknown MLS operation")
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
            if self._db.execute("SELECT COUNT(*) FROM mls_packages").fetchone()[0] >= MAX_PACKAGES:
                raise DeliveryCapacity("package directory full")
            self._db.execute("INSERT INTO mls_packages VALUES (?,?,?,?,?)", (reference, package, time.time() + 900, writer, pairing))
        return {"reference": encode_base64url(reference)}

    def _package_fetch(self, doc: dict) -> dict:
        reference = blob(doc, "reference", 32)
        try:
            pairing = hashlib.sha256(blob(doc, "pairingToken", 32)).digest()
        except MailboxError as error:
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
            if self._db.execute("SELECT COUNT(*) FROM mls_groups").fetchone()[0] >= MAX_GROUPS:
                raise DeliveryCapacity("group directory full")
            self._db.execute("INSERT INTO mls_groups(route,epoch) VALUES (?,0)", (route,))
            self._db.execute("INSERT INTO mls_writers(route,digest) VALUES (?,?)", (route, writer))
        return {}

    def _authorize(self, doc: dict, route: bytes, *, writing: bool = False) -> tuple:
        try:
            writer = hashlib.sha256(blob(doc, "authorization", 32)).digest()
        except MailboxError as error:
            raise DeliveryUnauthorized("writer token required") from error
        row = self._db.execute("SELECT ack,removal,removed_at FROM mls_writers WHERE route=? AND digest=?", (route, writer)).fetchone()
        if row is None or (row[1] is not None and (writing or row[0] >= row[1] or time.time() >= row[2] + 86400)):
            raise DeliveryUnauthorized("writer not authorized")
        return writer, row[1]

    def _fetch(self, doc: dict) -> dict:
        route = blob(doc, "group", 32)
        _, removal = self._authorize(doc, route)
        after = number(doc, "after")
        limit = number({"limit": doc.get("limit", 16)}, "limit")
        if not 1 <= limit <= 32:
            raise MailboxError("invalid limit")
        rows = self._db.execute(
            "SELECT cursor,epoch,kind,payload,welcome,package,removed_writer,added_writer FROM mls_entries WHERE route=? AND cursor>? AND cursor<=? ORDER BY cursor LIMIT ?",
            (route, after, removal if removal is not None else 2**53, limit),
        ).fetchall()
        return {"entries": [self._entry(row) for row in rows]}

    def _ack(self, doc: dict) -> dict:
        route = blob(doc, "route", 32)
        writer, removal = self._authorize(doc, route)
        cursor = number(doc, "cursor")
        head = self._db.execute("SELECT head FROM mls_groups WHERE route=?", (route,)).fetchone()[0]
        if cursor > head or (removal is not None and cursor > removal):
            raise MailboxError("cursor exceeds readable log")
        self._db.execute("UPDATE mls_writers SET ack=MAX(ack,?) WHERE route=? AND digest=?", (cursor, route, writer))
        self._prune()
        return {}

    def _prune(self) -> None:
        self._db.execute(
            "DELETE FROM mls_entries WHERE cursor <= (SELECT MIN(ack) FROM mls_writers WHERE mls_writers.route=mls_entries.route AND (removal IS NULL OR (ack<removal AND removed_at>?)))",
            (time.time() - 86400,),
        )

    def _append(self, doc: dict) -> dict:
        route = blob(doc, "group", 32)
        writer, _ = self._authorize(doc, route, writing=True)
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
            self._db.execute("INSERT INTO mls_rejections VALUES (?,?,?)", (route, digest, entry[0]))
            return {"error": "keyPackageUnavailable", "epoch": entry[0]}
        return self._accept_entry(route, entry)

    def _parse_entry(self, doc: dict, writer: bytes) -> tuple:
        epoch = number(doc, "epoch")
        kind = doc.get("kind")
        if kind not in ("commit", "application"):
            raise MailboxError("invalid kind")
        payload = blob(doc, "payload")
        welcome = blob(doc, "welcome") if doc.get("welcome") is not None else None
        package = blob(doc, "reference", 32) if doc.get("reference") is not None else None
        removed_writer = blob(doc, "removeWriter", 32) if doc.get("removeWriter") is not None else None
        added_writer = blob(doc, "addWriter", 32) if doc.get("addWriter") is not None else None
        if removed_writer is not None and (kind != "commit" or removed_writer == writer):
            raise MailboxError("invalid writer removal")
        if (welcome is None) != (package is None) or (welcome is None) != (added_writer is None) or (welcome is not None and kind != "commit"):
            raise MailboxError("Welcome requires commit and KeyPackage reference")
        return epoch, kind, payload, welcome, package, removed_writer, added_writer

    def _check_membership(self, route: bytes, entry: tuple) -> bool:
        _, _, _, _, package, removed_writer, added_writer = entry
        if removed_writer and not self._db.execute("SELECT 1 FROM mls_writers WHERE route=? AND digest=? AND removal IS NULL", (route, removed_writer)).fetchone():
            raise MailboxError("writer removal target is unknown")
        joining = self._db.execute("SELECT writer FROM mls_packages WHERE reference=?", (package,)).fetchone() if package else None
        if package and (not joining or joining[0] != added_writer):
            return False
        if joining and not self._db.execute("SELECT 1 FROM mls_writers WHERE route=? AND digest=? AND removal IS NULL", (route, added_writer)).fetchone():
            if self._db.execute("SELECT COUNT(*) FROM mls_writers WHERE route=? AND removal IS NULL", (route,)).fetchone()[0] >= 8:
                raise DeliveryCapacity("writer directory full")
        return True

    def _accept_entry(self, route: bytes, entry: tuple) -> dict:
        epoch, kind, payload, welcome, package, removed_writer, added_writer = entry
        count, size = self._db.execute(
            "SELECT COUNT(*),COALESCE(SUM(LENGTH(payload)+COALESCE(LENGTH(welcome),0)+COALESCE(LENGTH(package),0)),0) FROM mls_entries WHERE route=?", (route,)
        ).fetchone()
        if count >= MAX_ENTRIES or size + len(payload) + len(welcome or b"") + len(package or b"") > MAX_BYTES:
            raise DeliveryCapacity("delivery log full")
        cursor = self._db.execute(
            "INSERT INTO mls_entries(route,epoch,kind,payload,welcome,package,removed_writer,added_writer) VALUES (?,?,?,?,?,?,?,?)",
            (route, *entry),
        ).lastrowid
        self._db.execute("UPDATE mls_groups SET head=?,epoch=epoch+? WHERE route=?", (cursor, int(kind == "commit"), route))
        if package:
            self._db.execute("INSERT OR REPLACE INTO mls_writers(route,digest,ack) VALUES (?,?,?)", (route, added_writer, 0))
            self._db.execute("DELETE FROM mls_packages WHERE reference=?", (package,))
        if removed_writer:
            self._db.execute("UPDATE mls_writers SET removal=?,removed_at=? WHERE route=? AND digest=?", (cursor, time.time(), route, removed_writer))
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

    async def start(self) -> int:
        self._server = await asyncio.start_server(self._accept, "127.0.0.1", 0, limit=8192)
        return self._server.sockets[0].getsockname()[1]

    async def close(self) -> None:
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
            if method != "POST" or not target.startswith("/v2/mls/"):
                await write_http_response(writer, 404, {"error": "notFound", "version": VERSION})
                return
            await self.handle_request(target, headers, body, writer)
        except MailboxError as error:
            await write_http_response(writer, error.status, {"error": error.code, "version": VERSION})
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
                raise MailboxError("content type must be application/json")
            document = parse_mailbox_json(body)
            document.pop("authorization", None)
            authorization = headers.get("authorization", "")
            scheme, _, token = authorization.partition(" ")
            if scheme.lower() == "bearer":
                document["authorization"] = token
            result = await asyncio.to_thread(self.store.request, target.removeprefix("/v2/mls/"), document)
            await write_http_response(writer, 409 if "error" in result else 200, result)
        except MailboxError as error:
            await write_http_response(writer, error.status, {"error": error.code, "version": VERSION})
        except ConnectionError:
            raise
        except Exception:
            await write_http_response(writer, 500, {"error": "internalError", "version": VERSION})
