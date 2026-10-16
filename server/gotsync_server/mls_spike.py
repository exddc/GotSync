"""Experimental MLS delivery service. Not enabled by the production relay."""
from __future__ import annotations

import asyncio
import hashlib
import sqlite3
import threading
import time
from pathlib import Path
from typing import Any

from .mailbox import MailboxError, decode_canonical_base64url, encode_base64url

VERSION = 2
MAX_PAYLOAD = 448 * 1024
MAX_ENTRIES = 10_000
MAX_BYTES = 64 * 1024 * 1024
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
            CREATE TABLE IF NOT EXISTS mls_groups (route BLOB PRIMARY KEY, epoch INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS mls_writers (
                route BLOB NOT NULL, digest BLOB NOT NULL, PRIMARY KEY(route, digest)
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
                reference BLOB PRIMARY KEY, payload BLOB NOT NULL, expires REAL NOT NULL, writer BLOB NOT NULL
            );
        """)
        self._db.commit()

    def close(self) -> None:
        self._db.close()

    def request(self, operation: str, document: dict[str, Any]) -> dict[str, Any]:
        if type(document.get("version")) is not int or document["version"] != VERSION:
            raise MailboxError("unsupported version")
        with self._lock, self._db:
            self._db.execute("DELETE FROM mls_packages WHERE expires < ?", (time.time(),))
            result = self._request(operation, document)
            return {"version": VERSION, **result}

    def _request(self, operation: str, doc: dict[str, Any]) -> dict[str, Any]:
        if operation == "key-package/publish":
            package = blob(doc, "payload", maximum=65536)
            writer = hashlib.sha256(blob(doc, "authorization", 32)).digest()
            reference = hashlib.sha256(package).digest()
            existing = self._db.execute("SELECT writer FROM mls_packages WHERE reference=?", (reference,)).fetchone()
            if existing and existing[0] != writer:
                raise DeliveryConflict("package writer differs")
            if not existing:
                if self._db.execute("SELECT COUNT(*) FROM mls_packages").fetchone()[0] >= MAX_PACKAGES:
                    raise DeliveryCapacity("package directory full")
                self._db.execute("INSERT INTO mls_packages VALUES (?, ?, ?, ?)", (reference, package, time.time() + 900, writer))
            return {"reference": encode_base64url(reference)}
        if operation == "key-package/fetch":
            reference = blob(doc, "reference", 32)
            row = self._db.execute("SELECT payload FROM mls_packages WHERE reference=?", (reference,)).fetchone()
            return {"payload": encode_base64url(row[0]) if row else None}
        route = blob(doc, "group", 32)
        if operation == "create":
            writer = hashlib.sha256(blob(doc, "authorization", 32)).digest()
            if self._db.execute("SELECT 1 FROM mls_groups WHERE route=?", (route,)).fetchone():
                if not self._db.execute("SELECT 1 FROM mls_writers WHERE route=? AND digest=?", (route, writer)).fetchone():
                    raise DeliveryConflict("group already registered")
            else:
                if self._db.execute("SELECT COUNT(*) FROM mls_groups").fetchone()[0] >= MAX_GROUPS:
                    raise DeliveryCapacity("group directory full")
                self._db.execute("INSERT INTO mls_groups VALUES (?,0)", (route,))
                self._db.execute("INSERT INTO mls_writers VALUES (?,?)", (route, writer))
            return {}
        if operation == "fetch":
            after = number(doc, "after")
            rows = self._db.execute(
                "SELECT cursor,epoch,kind,payload,welcome,package,removed_writer,added_writer FROM mls_entries WHERE route=? AND cursor>? ORDER BY cursor LIMIT 1",
                (route, after),
            ).fetchall()
            return {"entries": [self._entry(row) for row in rows]}
        if operation != "append":
            raise MailboxError("unknown MLS operation")
        writer = hashlib.sha256(blob(doc, "authorization", 32)).digest()
        if not self._db.execute("SELECT 1 FROM mls_writers WHERE route=? AND digest=?", (route, writer)).fetchone():
            raise DeliveryUnauthorized("writer not authorized")
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
        duplicate = self._db.execute(
            "SELECT cursor,epoch,kind,payload,welcome,package,removed_writer,added_writer FROM mls_entries WHERE route=? AND payload=?", (route, payload)
        ).fetchone()
        if duplicate:
            if (epoch, kind, welcome, package, removed_writer, added_writer) != (duplicate[1], duplicate[2], duplicate[4], duplicate[5], duplicate[6], duplicate[7]):
                raise DeliveryConflict("retry differs from accepted message")
            return {"entry": self._entry(duplicate)}
        digest = hashlib.sha256(payload).digest()
        rejected = self._db.execute("SELECT epoch FROM mls_rejections WHERE route=? AND digest=?", (route, digest)).fetchone()
        if rejected:
            return {"error": "keyPackageUnavailable", "epoch": rejected[0]}
        current = self._db.execute("SELECT epoch FROM mls_groups WHERE route=?", (route,)).fetchone()
        if current is None or epoch != current[0]:
            raise DeliveryConflict("refetch the winning commit")
        if removed_writer and not self._db.execute("SELECT 1 FROM mls_writers WHERE route=? AND digest=?", (route, removed_writer)).fetchone():
            raise MailboxError("writer removal target is unknown")
        joining_writer = self._db.execute("SELECT writer FROM mls_packages WHERE reference=?", (package,)).fetchone() if package else None
        if package and (not joining_writer or joining_writer[0] != added_writer):
            if self._db.execute("SELECT COUNT(*) FROM mls_rejections").fetchone()[0] >= MAX_ENTRIES:
                raise DeliveryCapacity("rejection journal full")
            self._db.execute("INSERT INTO mls_rejections VALUES (?,?,?)", (route, digest, epoch))
            return {"error": "keyPackageUnavailable", "epoch": epoch}
        if joining_writer and not self._db.execute("SELECT 1 FROM mls_writers WHERE route=? AND digest=?", (route, joining_writer[0])).fetchone():
            if self._db.execute("SELECT COUNT(*) FROM mls_writers WHERE route=?", (route,)).fetchone()[0] >= 8:
                raise DeliveryCapacity("writer directory full")
        count, size = self._db.execute("SELECT COUNT(*),COALESCE(SUM(LENGTH(payload)+COALESCE(LENGTH(welcome),0)),0) FROM mls_entries").fetchone()
        if count >= MAX_ENTRIES or size + len(payload) + len(welcome or b"") > MAX_BYTES:
            raise DeliveryCapacity("delivery log full")
        cursor = self._db.execute(
            "INSERT INTO mls_entries(route,epoch,kind,payload,welcome,package,removed_writer,added_writer) VALUES (?,?,?,?,?,?,?,?)",
            (route, epoch, kind, payload, welcome, package, removed_writer, added_writer),
        ).lastrowid
        if kind == "commit":
            self._db.execute("UPDATE mls_groups SET epoch=epoch+1 WHERE route=?", (route,))
        if package:
            self._db.execute("INSERT OR IGNORE INTO mls_writers VALUES (?,?)", (route, joining_writer[0]))
            self._db.execute("DELETE FROM mls_packages WHERE reference=?", (package,))
        if removed_writer:
            self._db.execute("DELETE FROM mls_writers WHERE route=? AND digest=?", (route, removed_writer))
        return {"entry": self._entry((cursor, epoch, kind, payload, welcome, package, removed_writer, added_writer))}

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
        from .server import _read_http_json_request, _parse_mailbox_json, _write_http_response
        try:
            method, target, headers, body = await _read_http_json_request(reader, maximum_body_bytes=1024 * 1024)
            if method != "POST" or not target.startswith("/v2/mls/"):
                await _write_http_response(writer, 404, {"error": "notFound", "version": VERSION})
                return
            if headers.get("content-type", "").split(";")[0].strip() != "application/json":
                raise MailboxError("content type must be application/json")
            document = _parse_mailbox_json(body)
            document.pop("authorization", None)
            authorization = headers.get("authorization", "")
            scheme, _, token = authorization.partition(" ")
            if scheme.lower() == "bearer":
                document["authorization"] = token
            result = self.store.request(target.removeprefix("/v2/mls/"), document)
            await _write_http_response(writer, 409 if "error" in result else 200, result)
        except MailboxError as error:
            await _write_http_response(writer, error.status, {"error": error.code, "version": VERSION})
        except (ConnectionError, asyncio.IncompleteReadError):
            pass
        except Exception:
            try:
                await _write_http_response(writer, 500, {"error": "internalError", "version": VERSION})
            except ConnectionError:
                pass
        finally:
            writer.close()
            try:
                await writer.wait_closed()
            except ConnectionError:
                pass
