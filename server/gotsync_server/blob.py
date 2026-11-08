"""Durable relay cache of encrypted blob parts.

Nothing here runs at import. A `BlobStore` opens its own SQLite database and
part directory when constructed and never touches MLS state or locks.

Lock rule: `BlobStore._lock` serializes metadata and the in-memory ledgers.
No part file is created, written, synced, renamed, read or unlinked while it is
held. Ownership of every temporary or final file and every physical
reservation stays with its ticket until the worker function returns; a
deadline only marks the ticket cancelled.
"""
from __future__ import annotations

import asyncio
import errno
import hashlib
import math
import os
import re
import secrets
import sqlite3
import stat
import threading
import time
from collections.abc import Callable, Iterable, Iterator
from concurrent.futures import Executor
from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, NamedTuple
from urllib.parse import quote

from .blob_format import ID_BYTES, PART_BYTES, Manifest, identifier
from .http import RequestError

FORMAT_VERSION = 1
APPLICATION_ID = 0x47534231
GLOBAL_SCOPE = b"\x00"
BLOCK_BYTES = 4096
SQLITE_READONLY_ROLLBACK = 776
TEMP_DIRECTORY = "tmp"
_ROUTE_DIRECTORY = re.compile(r"[0-9a-f]{64}")
_PART_NAME = re.compile(r"([0-9a-f]{64})\.([0-9]|1[0-9])\.[0-9a-f]{16}")
_TEMP_NAME = re.compile(r"[0-9a-f]{32}\.part")

SCHEMA = """
CREATE TABLE blob_objects (
    route BLOB NOT NULL, object BLOB NOT NULL, length INTEGER NOT NULL, parts INTEGER NOT NULL,
    part_hashes BLOB NOT NULL, complete INTEGER NOT NULL, created_at REAL NOT NULL, touched_at REAL NOT NULL,
    expires_at REAL NOT NULL, released INTEGER NOT NULL, lease_writer BLOB, lease_until REAL,
    creator BLOB NOT NULL, PRIMARY KEY (route, object)
) STRICT;
CREATE INDEX blob_object_expiry ON blob_objects(expires_at);
CREATE INDEX blob_object_creator ON blob_objects(route, creator, complete);
CREATE TABLE blob_parts (
    route BLOB NOT NULL, object BLOB NOT NULL, idx INTEGER NOT NULL, file TEXT NOT NULL UNIQUE,
    size INTEGER NOT NULL, created_at REAL NOT NULL, PRIMARY KEY (route, object, idx)
) STRICT;
CREATE TABLE blob_wanted (
    route BLOB NOT NULL, object BLOB NOT NULL, wanted_at REAL NOT NULL, PRIMARY KEY (route, object)
) STRICT;
CREATE INDEX blob_wanted_age ON blob_wanted(wanted_at);
CREATE TABLE blob_usage (
    scope BLOB PRIMARY KEY, logical_bytes INTEGER NOT NULL, objects INTEGER NOT NULL, incomplete INTEGER NOT NULL
) STRICT;
CREATE TABLE blob_doomed (file TEXT PRIMARY KEY, size INTEGER NOT NULL) STRICT;
"""


class BlobObjectMissing(RequestError):
    status = 404
    code = "objectMissing"


class BlobPartMissing(RequestError):
    status = 404
    code = "partMissing"


class BlobPartMismatch(RequestError):
    status = 409
    code = "partMismatch"


class BlobBusy(RequestError):
    status = 429
    code = "blobBusy"


class BlobGroupQuota(RequestError):
    status = 507
    code = "blobGroupQuota"


class BlobCapacity(RequestError):
    status = 507
    code = "blobCapacity"


class BlobCleanupBacklog(RequestError):
    status = 507
    code = "blobCleanupBacklog"


class BlobCancelled(Exception):
    """The worker found its ticket cancelled; nothing was published."""


class BlobDeadline(Exception):
    """The awaiting request gave up; the worker keeps its resources until it returns."""


class BlobStoreError(Exception):
    """The blob database or directory cannot be used. Nothing was recreated or converted."""


class BlobStoreUnsupported(BlobStoreError):
    pass


class BlobStoreCorrupt(BlobStoreError):
    pass


def round_up(size: int) -> int:
    return -(-size // BLOCK_BYTES) * BLOCK_BYTES


@dataclass(frozen=True)
class BlobLimits:
    group_logical_bytes: int = 201_326_592
    group_objects: int = 1_200
    group_incomplete: int = 8
    writer_incomplete: int = 2
    global_logical_bytes: int = 8 * 1024**3
    global_objects: int = 100_000
    global_incomplete: int = 512
    max_physical_bytes: int = 8 * 1024**3 + 512 * 1024**2
    disk_reserve_bytes: int = 1024**3
    doomed_max_bytes: int = 512 * 1024**2
    doomed_max_files: int = 20_000
    metadata_allowance_bytes: int = 4 * 1024**2
    complete_seconds: float = 30 * 86400
    incomplete_seconds: float = 86400
    released_seconds: float = 86400
    wanted_seconds: float = 7 * 86400
    touch_resolution_seconds: float = 3600
    lease_seconds: float = 600
    wanted_per_group: int = 64
    objects_per_request: int = 16
    expiry_batch: int = 64
    cleanup_batch: int = 64

    def __post_init__(self) -> None:
        for name, value in self.__dict__.items():
            valid = type(value) is int and value >= 0 if name in _INTEGER_LIMITS else (
                type(value) in (int, float) and 0 < value < math.inf)
            if not valid:
                raise ValueError(f"invalid blob limit {name}")
        if min(self.expiry_batch, self.cleanup_batch, self.objects_per_request) < 1:
            raise ValueError("blob batches must be positive")


_INTEGER_LIMITS = {
    "group_logical_bytes", "group_objects", "group_incomplete", "writer_incomplete", "global_logical_bytes",
    "global_objects", "global_incomplete", "max_physical_bytes", "disk_reserve_bytes", "doomed_max_bytes",
    "doomed_max_files", "metadata_allowance_bytes", "wanted_per_group", "objects_per_request", "expiry_batch",
    "cleanup_batch",
}


class BlobFiles:
    """Every part-file operation of the store, relative to directory descriptors.

    Names are validated before use and nothing follows a symbolic link. Tests
    substitute this class to inject faults and pauses.
    """

    lock_held: Callable[[], bool] = staticmethod(lambda: False)

    def __init__(self, directory: Path) -> None:
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        self._root = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            self._make_directory(self._root, TEMP_DIRECTORY)
            self._temp = os.open(TEMP_DIRECTORY, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=self._root)
        except BaseException:
            os.close(self._root)
            raise

    def close(self) -> None:
        os.close(self._temp)
        os.close(self._root)

    def free_bytes(self) -> int:
        status = os.fstatvfs(self._root)
        return status.f_bavail * status.f_frsize

    def write_temp(self, name: str, data: bytes) -> None:
        self._unlocked()
        _require(_TEMP_NAME, name)
        descriptor = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=self._temp)
        try:
            view = memoryview(data)
            while view:
                view = view[os.write(descriptor, view):]
            self.sync_file(descriptor)
        finally:
            os.close(descriptor)

    def sync_file(self, descriptor: int) -> None:
        os.fsync(descriptor)

    def sync_directory(self, descriptor: int) -> None:
        os.fsync(descriptor)

    def publish(self, temp: str, route: str, name: str) -> None:
        self._unlocked()
        _require(_TEMP_NAME, temp)
        _require(_PART_NAME, name)
        directory = self._route_directory(route, create=True)
        try:
            os.rename(temp, name, src_dir_fd=self._temp, dst_dir_fd=directory)
            self.sync_directory(directory)
        finally:
            os.close(directory)

    def read(self, route: str, name: str, size: int) -> bytes | None:
        self._unlocked()
        _require(_PART_NAME, name)
        try:
            directory = self._route_directory(route, create=False)
        except FileNotFoundError:
            return None
        try:
            descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory)
        except (FileNotFoundError, OSError) as error:
            if isinstance(error, FileNotFoundError) or error.errno == errno.ELOOP:
                return None
            raise
        finally:
            os.close(directory)
        try:
            if not stat.S_ISREG(os.fstat(descriptor).st_mode):
                return None
            chunks = []
            remaining = size + 1
            while remaining:
                chunk = os.read(descriptor, remaining)
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
            return b"".join(chunks)
        finally:
            os.close(descriptor)

    def unlink(self, file: str) -> None:
        """Removes a stored `route/name` or `tmp/name` entry. A missing entry counts as removed."""
        self._unlocked()
        directory_name, name = _split(file)
        try:
            directory = (os.open(TEMP_DIRECTORY, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=self._root)
                         if directory_name == TEMP_DIRECTORY else self._route_directory(directory_name, create=False))
        except FileNotFoundError:
            return
        try:
            os.unlink(name, dir_fd=directory)
        except FileNotFoundError:
            pass
        finally:
            os.close(directory)

    def size(self, file: str) -> int | None:
        """Size of a regular file at `route/name`, else None."""
        self._unlocked()
        directory_name, name = _split(file)
        try:
            directory = self._route_directory(directory_name, create=False)
        except OSError:
            return None
        try:
            status = os.stat(name, dir_fd=directory, follow_symlinks=False)
        except FileNotFoundError:
            return None
        finally:
            os.close(directory)
        return status.st_size if stat.S_ISREG(status.st_mode) else None

    def clear_temp(self) -> tuple[int, list[str]]:
        self._unlocked()
        removed, unexpected = 0, []
        with os.scandir(self._temp) as entries:
            for entry in entries:
                if entry.is_dir(follow_symlinks=False):
                    unexpected.append(f"{TEMP_DIRECTORY}/{entry.name}")
                    continue
                os.unlink(entry.name, dir_fd=self._temp)
                removed += 1
        return removed, unexpected

    def scan(self) -> Iterator[tuple[str, str]]:
        """Yields `(directory, name)` for every entry below the root except `tmp/`."""
        self._unlocked()
        with os.scandir(self._root) as directories:
            names = [entry.name for entry in directories]
        for directory in names:
            if directory == TEMP_DIRECTORY:
                continue
            if not _ROUTE_DIRECTORY.fullmatch(directory):
                yield "", directory
                continue
            try:
                descriptor = self._route_directory(directory, create=False)
            except OSError:
                yield "", directory
                continue
            try:
                with os.scandir(descriptor) as entries:
                    files = [entry.name for entry in entries]
            finally:
                os.close(descriptor)
            if not files:
                try:
                    os.rmdir(directory, dir_fd=self._root)
                except OSError:
                    pass
            for name in files:
                yield directory, name

    def _unlocked(self) -> None:
        if self.lock_held():
            raise RuntimeError("blob file I/O while holding the blob lock")

    def _route_directory(self, route: str, *, create: bool) -> int:
        _require(_ROUTE_DIRECTORY, route)
        if create:
            self._make_directory(self._root, route)
        return os.open(route, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=self._root)

    def _make_directory(self, parent: int, name: str) -> None:
        try:
            os.mkdir(name, 0o700, dir_fd=parent)
        except FileExistsError:
            return
        self.sync_directory(parent)


def _require(pattern: re.Pattern[str], name: str) -> None:
    if not pattern.fullmatch(name):
        raise ValueError(f"invalid blob file name {name!r}")


def _split(file: str) -> tuple[str, str]:
    directory, _, name = file.partition("/")
    if directory == TEMP_DIRECTORY:
        _require(_TEMP_NAME, name)
    else:
        _require(_ROUTE_DIRECTORY, directory)
        _require(_PART_NAME, name)
    return directory, name


class PutResult(NamedTuple):
    stored: bool
    complete: bool


class BlobTicket:
    """One admitted part request. Its reservation and files belong to it until its worker returns."""

    def __init__(self, kind: str, route: bytes, object_: bytes, index: int, size: int, part_hash: bytes,
                 reservation: int, file: str | None = None) -> None:
        self.kind = kind
        self.route = route
        self.object = object_
        self.index = index
        self.size = size
        self.part_hash = part_hash
        self.reservation = reservation
        self.file = file
        self.files: list[str] = []
        self.state = "admitted"
        self.started = False


class _OwnedLock:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._owner: int | None = None

    def __enter__(self) -> None:
        self._lock.acquire()
        self._owner = threading.get_ident()

    def __exit__(self, *_: object) -> None:
        self._owner = None
        self._lock.release()

    def held(self) -> bool:
        return self._owner == threading.get_ident()


@dataclass
class ExpiryReport:
    objects: int = 0
    parts: int = 0
    wanted: int = 0
    unlinked: int = 0
    failed_unlinks: int = 0


@dataclass
class StartupReport:
    recovered_journal: bool = False
    temporary_removed: int = 0
    unreferenced_removed: int = 0
    rows_dropped: int = 0
    doomed_finished: int = 0
    unexpected: list[str] = field(default_factory=list)


class BlobStore:
    def __init__(
        self, database: str | os.PathLike[str], directory: str | os.PathLike[str], *,
        limits: BlobLimits = BlobLimits(), clock: Callable[[], float] = time.time,
        files: Callable[[Path], BlobFiles] = BlobFiles,
    ) -> None:
        self.limits = limits
        self._clock = clock
        self._lock = _OwnedLock()
        self._database_path = Path(database)
        self._journal_path = Path(f"{self._database_path}-journal")
        self.startup = StartupReport()
        self._db = self._open_database()
        try:
            self._files = files(Path(directory))
        except OSError as error:
            self._db.close()
            raise BlobStoreUnsupported(f"blob directory unusable: {error}") from error
        except BaseException:
            self._db.close()
            raise
        self._files.lock_held = self._lock.held
        self._committed = 0
        self._doomed = 0
        self._doomed_files = 0
        self._outstanding = 0
        self._journal_peak = 0
        self._live: set[BlobTicket] = set()
        self._cleaning: set[str] = set()
        try:
            self._reconcile()
        except BaseException:
            self._files.close()
            self._db.close()
            raise

    # Database opening and validation

    def _open_database(self) -> sqlite3.Connection:
        path = self._database_path
        try:
            mode = os.lstat(path).st_mode
        except FileNotFoundError:
            self._create_database(path)
            mode = os.lstat(path).st_mode
        if not stat.S_ISREG(mode):
            raise BlobStoreUnsupported("blob database path is not a regular file")
        try:
            inspector = sqlite3.connect(f"file:{quote(str(path))}?mode=ro", uri=True, isolation_level=None)
        except sqlite3.Error as error:
            raise BlobStoreCorrupt(f"blob database unreadable: {error}") from error
        recovered = False
        try:
            self._inspect(inspector)
        except sqlite3.Error as error:
            if getattr(error, "sqlite_errorcode", None) != SQLITE_READONLY_ROLLBACK:
                raise BlobStoreCorrupt(f"blob database unreadable: {error}") from error
            recovered = True
        finally:
            inspector.close()
        db = sqlite3.connect(path, isolation_level=None, check_same_thread=False)
        try:
            if recovered:
                self._inspect(db)
                self.startup.recovered_journal = True
            for pragma in ("journal_mode=DELETE", "synchronous=FULL", "fullfsync=ON", "secure_delete=ON",
                           "foreign_keys=OFF"):
                db.execute(f"PRAGMA {pragma}")
        except sqlite3.Error as error:
            db.close()
            raise BlobStoreCorrupt(f"blob database unreadable: {error}") from error
        except BaseException:
            db.close()
            raise
        return db

    @staticmethod
    def _create_database(path: Path) -> None:
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        staging = Path(f"{path}.creating")
        for leftover in (staging, Path(f"{staging}-journal")):
            if leftover.is_symlink() or leftover.exists():
                leftover.unlink()
        os.close(os.open(staging, os.O_CREAT | os.O_EXCL | os.O_RDWR | os.O_NOFOLLOW, 0o600))
        db = sqlite3.connect(staging, isolation_level=None)
        try:
            db.execute("PRAGMA journal_mode=DELETE")
            db.execute("PRAGMA synchronous=FULL")
            db.executescript(SCHEMA)
            db.execute("INSERT INTO blob_usage VALUES (?, 0, 0, 0)", (GLOBAL_SCOPE,))
            db.execute(f"PRAGMA application_id = {APPLICATION_ID}")
            db.execute(f"PRAGMA user_version = {FORMAT_VERSION}")
        finally:
            db.close()
        descriptor = os.open(staging, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        os.rename(staging, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)

    def _inspect(self, db: sqlite3.Connection) -> None:
        db.execute("BEGIN")
        try:
            application = db.execute("PRAGMA application_id").fetchone()[0]
            version = db.execute("PRAGMA user_version").fetchone()[0]
            if application != APPLICATION_ID or version != FORMAT_VERSION:
                raise BlobStoreUnsupported(f"unsupported blob database (application {application}, version {version})")
            mode = db.execute("PRAGMA journal_mode").fetchone()[0]
            if mode != "delete":
                raise BlobStoreUnsupported(f"unsupported blob database journal mode {mode}")
            if db.execute("PRAGMA quick_check").fetchall() != [("ok",)]:
                raise BlobStoreCorrupt("blob database failed quick_check")
            if _schema(db) != _expected_schema():
                raise BlobStoreCorrupt("unexpected blob database schema")
            _validate_contents(db)
        finally:
            if db.in_transaction:
                db.execute("ROLLBACK")

    # Ledgers and transactions

    @contextmanager
    def _transaction(self) -> Iterator[sqlite3.Connection]:
        assert self._lock.held()
        self._db.execute("BEGIN IMMEDIATE")
        try:
            yield self._db
            try:
                self._journal_peak = max(self._journal_peak, self._journal_path.stat().st_size)
            except FileNotFoundError:
                pass
            self._db.execute("COMMIT")
        except BaseException:
            if self._db.in_transaction:
                self._db.execute("ROLLBACK")
            raise

    def _database_bytes(self) -> int:
        return self._database_path.stat().st_size + max(self.limits.metadata_allowance_bytes, self._journal_peak)

    def ledger(self) -> dict[str, int]:
        with self._lock:
            return {
                "committed": self._committed, "doomed": self._doomed, "doomedFiles": self._doomed_files,
                "outstanding": self._outstanding, "database": self._database_bytes(),
                "journalPeak": self._journal_peak, "liveTickets": len(self._live),
            }

    def usage(self, route: bytes = GLOBAL_SCOPE) -> tuple[int, int, int]:
        with self._lock:
            row = self._db.execute("SELECT logical_bytes, objects, incomplete FROM blob_usage WHERE scope=?",
                                   (route,)).fetchone()
            return tuple(row) if row else (0, 0, 0)

    def lock_held(self) -> bool:
        return self._lock.held()

    def _adjust(self, db: sqlite3.Connection, route: bytes, logical: int, objects: int, incomplete: int) -> None:
        for scope in (route, GLOBAL_SCOPE):
            db.execute(
                "INSERT INTO blob_usage VALUES (?, ?, ?, ?) ON CONFLICT(scope) DO UPDATE SET "
                "logical_bytes=logical_bytes+excluded.logical_bytes, objects=objects+excluded.objects, "
                "incomplete=incomplete+excluded.incomplete", (scope, logical, objects, incomplete))
        db.execute("DELETE FROM blob_usage WHERE scope=? AND objects=0", (route,))

    # Metadata operations (no file I/O)

    def begin(self, route: bytes, object_: bytes, length: int, part_hashes: Iterable[bytes], *,
              writer: bytes) -> dict[str, Any]:
        manifest = Manifest.validated(route, object_, length, tuple(part_hashes))
        writer = identifier(writer, "writer")
        now = self._clock()
        limits = self.limits
        with self._lock, self._transaction() as db:
            row = db.execute(
                "SELECT length, part_hashes, complete, released, touched_at, lease_writer, lease_until "
                "FROM blob_objects WHERE route=? AND object=?", (manifest.route, manifest.object)).fetchone()
            if row is None:
                logical, objects, incomplete = _usage(db, manifest.route)
                global_logical, global_objects, global_incomplete = _usage(db, GLOBAL_SCOPE)
                if (logical + manifest.length > limits.group_logical_bytes or objects >= limits.group_objects
                        or incomplete >= limits.group_incomplete):
                    raise BlobGroupQuota("blob group quota reached")
                if (global_logical + manifest.length > limits.global_logical_bytes
                        or global_objects >= limits.global_objects or global_incomplete >= limits.global_incomplete):
                    raise BlobCapacity("blob capacity reached")
                writer_incomplete = db.execute(
                    "SELECT COUNT(*) FROM blob_objects WHERE route=? AND creator=? AND complete=0",
                    (manifest.route, writer)).fetchone()[0]
                if writer_incomplete >= limits.writer_incomplete:
                    raise BlobBusy("writer has too many incomplete blobs")
                db.execute(
                    "INSERT INTO blob_objects VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?, 0, ?, ?, ?)",
                    (manifest.route, manifest.object, manifest.length, manifest.parts, b"".join(manifest.part_hashes),
                     now, now, now + limits.incomplete_seconds, writer, now + limits.lease_seconds, writer))
                self._adjust(db, manifest.route, manifest.length, 1, 1)
                return {"complete": False, "present": [], "leasedByOther": False}
            length, hashes, complete, released, touched_at, lease_writer, lease_until = row
            if (length, hashes) != (manifest.length, b"".join(manifest.part_hashes)):
                raise BlobStoreCorrupt("stored manifest differs from its object identity")
            present = _present(db, manifest.route, manifest.object)
            if complete:
                self._touch(db, manifest.route, manifest.object, now, touched_at, released)
                return {"complete": True, "present": present, "leasedByOther": False}
            leased_by_other = lease_writer != writer and lease_until is not None and lease_until > now
            if not leased_by_other:
                db.execute("UPDATE blob_objects SET lease_writer=?, lease_until=?, released=0 WHERE route=? AND object=?",
                           (writer, now + limits.lease_seconds, manifest.route, manifest.object))
            return {"complete": False, "present": present, "leasedByOther": leased_by_other}

    def manifest(self, route: bytes, object_: bytes) -> dict[str, Any]:
        route, object_ = identifier(route, "route"), identifier(object_, "object")
        with self._lock:
            row = self._db.execute("SELECT length, part_hashes, complete FROM blob_objects WHERE route=? AND object=?",
                                   (route, object_)).fetchone()
            if row is None:
                raise BlobObjectMissing("blob object missing")
            return {"length": row[0], "parts": _hashes(row[1]), "present": _present(self._db, route, object_),
                    "complete": bool(row[2])}

    def want(self, route: bytes, objects: Iterable[bytes]) -> int:
        route = identifier(route, "route")
        objects = self._object_list(objects)
        now = self._clock()
        with self._lock, self._transaction() as db:
            accepted = 0
            count = db.execute("SELECT COUNT(*) FROM blob_wanted WHERE route=?", (route,)).fetchone()[0]
            for object_ in objects:
                complete = db.execute("SELECT complete FROM blob_objects WHERE route=? AND object=?",
                                      (route, object_)).fetchone()
                if complete is not None and complete[0]:
                    continue
                exists = db.execute("SELECT 1 FROM blob_wanted WHERE route=? AND object=?", (route, object_)).fetchone()
                if exists is None:
                    if count >= self.limits.wanted_per_group:
                        continue
                    count += 1
                db.execute("INSERT INTO blob_wanted VALUES (?, ?, ?) ON CONFLICT(route, object) DO UPDATE "
                           "SET wanted_at=excluded.wanted_at", (route, object_, now))
                accepted += 1
            return accepted

    def wanted(self, route: bytes) -> list[bytes]:
        route = identifier(route, "route")
        cutoff = self._clock() - self.limits.wanted_seconds
        with self._lock:
            rows = self._db.execute(
                "SELECT w.object FROM blob_wanted w LEFT JOIN blob_objects o ON o.route=w.route AND o.object=w.object "
                "WHERE w.route=? AND w.wanted_at>? AND COALESCE(o.complete, 0)=0 ORDER BY w.wanted_at, w.object LIMIT ?",
                (route, cutoff, self.limits.wanted_per_group)).fetchall()
            return [row[0] for row in rows]

    def release(self, route: bytes, objects: Iterable[bytes]) -> None:
        route = identifier(route, "route")
        objects = self._object_list(objects)
        deadline = self._clock() + self.limits.released_seconds
        with self._lock, self._transaction() as db:
            for object_ in objects:
                db.execute("UPDATE blob_objects SET released=1, expires_at=MIN(expires_at, ?) WHERE route=? AND object=?",
                           (deadline, route, object_))

    def routes(self) -> list[bytes]:
        with self._lock:
            return [row[0] for row in self._db.execute("SELECT scope FROM blob_usage WHERE scope<>?", (GLOBAL_SCOPE,))]

    def _object_list(self, objects: Iterable[bytes]) -> list[bytes]:
        values = [identifier(value, "object") for value in objects]
        if not 1 <= len(values) <= self.limits.objects_per_request or len(set(values)) != len(values):
            raise RequestError("invalid object list")
        return values

    def _touch(self, db: sqlite3.Connection, route: bytes, object_: bytes, now: float, touched_at: float,
               released: int) -> None:
        if released or now - touched_at >= self.limits.touch_resolution_seconds:
            db.execute("UPDATE blob_objects SET touched_at=?, expires_at=?, released=0 WHERE route=? AND object=?",
                       (now, now + self.limits.complete_seconds, route, object_))

    # Part requests

    def admit_put(self, route: bytes, object_: bytes, index: int, size: int, *,
                  writer: bytes) -> BlobTicket | PutResult:
        """Checks the manifest and reserves physical space before any body byte is read."""
        route, object_ = identifier(route, "route"), identifier(object_, "object")
        identifier(writer, "writer")
        with self._lock:
            manifest, complete = self._stored_manifest(route, object_)
            if size != manifest.part_bytes(index):
                raise RequestError("part size does not match the manifest")
            if self._part_file(route, object_, index) is not None:
                return PutResult(True, complete)
            need = round_up(size)
            self._admit_physical(need)
            self._outstanding += need
            ticket = BlobTicket("put", route, object_, index, size, manifest.part_hashes[index], need)
            self._live.add(ticket)
            return ticket

    def put_part(self, ticket: BlobTicket, body: bytes) -> PutResult:
        """Worker function: verify, write, sync and commit one part. Never call while holding the lock."""
        assert ticket.kind == "put"
        proceed = self._start(ticket)
        try:
            if not proceed:
                raise BlobCancelled()
            if len(body) != ticket.size or hashlib.sha256(body).digest() != ticket.part_hash:
                raise BlobPartMismatch("part does not match its hash")
            temp = f"{secrets.token_hex(16)}.part"
            route_name = ticket.route.hex()
            final = f"{route_name}/{ticket.object.hex()}.{ticket.index}.{secrets.token_hex(8)}"
            ticket.files += [f"{TEMP_DIRECTORY}/{temp}", final]
            try:
                self._files.write_temp(temp, body)
                self._files.publish(temp, route_name, final.partition("/")[2])
            except OSError as error:
                if error.errno in (errno.ENOSPC, errno.EDQUOT):
                    raise BlobCapacity("blob disk full") from error
                raise
            ticket.files.remove(f"{TEMP_DIRECTORY}/{temp}")
            return self._commit_part(ticket, final)
        finally:
            self._dispose(ticket)

    def _commit_part(self, ticket: BlobTicket, file: str) -> PutResult:
        now = self._clock()
        with self._lock:
            if ticket.state == "cancelled":
                raise BlobCancelled()
            try:
                with self._transaction() as db:
                    row = db.execute("SELECT parts, complete FROM blob_objects WHERE route=? AND object=?",
                                     (ticket.route, ticket.object)).fetchone()
                    if row is None:
                        ticket.state = "decided"
                        raise BlobObjectMissing("blob object missing")
                    parts, complete = row
                    if self._part_file(ticket.route, ticket.object, ticket.index) is not None:
                        ticket.state = "decided"
                        return PutResult(True, bool(complete))
                    db.execute("INSERT INTO blob_parts VALUES (?, ?, ?, ?, ?, ?)",
                               (ticket.route, ticket.object, ticket.index, file, ticket.size, now))
                    present = db.execute("SELECT COUNT(*) FROM blob_parts WHERE route=? AND object=?",
                                         (ticket.route, ticket.object)).fetchone()[0]
                    complete = present == parts
                    if complete:
                        db.execute("UPDATE blob_objects SET complete=1, touched_at=?, expires_at=?, lease_writer=NULL, "
                                   "lease_until=NULL WHERE route=? AND object=?",
                                   (now, now + self.limits.complete_seconds, ticket.route, ticket.object))
                        db.execute("DELETE FROM blob_wanted WHERE route=? AND object=?", (ticket.route, ticket.object))
                        self._adjust(db, ticket.route, 0, 0, -1)
                    else:
                        db.execute("UPDATE blob_objects SET expires_at=MAX(expires_at, ?) WHERE route=? AND object=?",
                                   (now + self.limits.incomplete_seconds, ticket.route, ticket.object))
            except sqlite3.Error as error:
                if getattr(error, "sqlite_errorcode", None) == sqlite3.SQLITE_FULL:
                    raise BlobCapacity("blob metadata disk full") from error
                raise
            ticket.state = "decided"
            ticket.files.remove(file)
            self._committed += ticket.reservation
            self._outstanding -= ticket.reservation
            ticket.reservation = 0
            return PutResult(True, complete)

    def admit_get(self, route: bytes, object_: bytes, index: int) -> BlobTicket:
        route, object_ = identifier(route, "route"), identifier(object_, "object")
        with self._lock:
            manifest, _ = self._stored_manifest(route, object_)
            size = manifest.part_bytes(index)
            file = self._part_file(route, object_, index)
            if file is None:
                raise BlobPartMissing("blob part missing")
            ticket = BlobTicket("get", route, object_, index, size, manifest.part_hashes[index], 0, file)
            self._live.add(ticket)
            return ticket

    def get_part(self, ticket: BlobTicket) -> bytes:
        """Worker function: read and re-hash one part. A damaged part is dropped and reported missing."""
        assert ticket.kind == "get" and ticket.file is not None
        proceed = self._start(ticket)
        try:
            if not proceed:
                raise BlobCancelled()
            _, name = _split(ticket.file)
            data = self._files.read(ticket.route.hex(), name, ticket.size)
            if data is None or len(data) != ticket.size or hashlib.sha256(data).digest() != ticket.part_hash:
                if self._drop_part(ticket.route, ticket.object, ticket.index, ticket.file):
                    self._unlink_doomed([(ticket.file, ticket.size)])
                raise BlobPartMissing("blob part missing")
            now = self._clock()
            with self._lock:
                row = self._db.execute("SELECT complete, touched_at, released FROM blob_objects WHERE route=? AND object=?",
                                       (ticket.route, ticket.object)).fetchone()
                if row is not None and row[0] and (row[2] or now - row[1] >= self.limits.touch_resolution_seconds):
                    with self._transaction() as db:
                        self._touch(db, ticket.route, ticket.object, now, row[1], row[2])
                ticket.state = "decided"
            return data
        finally:
            self._dispose(ticket)

    def cancel(self, ticket: BlobTicket) -> bool:
        """Marks an undecided ticket cancelled. Its resources stay owned until its worker returns."""
        with self._lock:
            if ticket.state in ("admitted", "running"):
                ticket.state = "cancelled"
                return True
            return ticket.state == "cancelled"

    def abandon(self, ticket: BlobTicket) -> None:
        """Releases a ticket whose worker never started, such as after a failed body read."""
        with self._lock:
            if ticket.started or ticket.state == "returned":
                raise RuntimeError("ticket worker already started")
            ticket.started = True
            ticket.state = "cancelled"
        self._dispose(ticket)

    def cancel_all(self) -> None:
        with self._lock:
            for ticket in self._live:
                if ticket.state in ("admitted", "running"):
                    ticket.state = "cancelled"

    def _start(self, ticket: BlobTicket) -> bool:
        with self._lock:
            if ticket.started:
                raise RuntimeError("ticket worker already started")
            ticket.started = True
            if ticket.state == "cancelled":
                return False
            ticket.state = "running"
            return True

    def _dispose(self, ticket: BlobTicket) -> None:
        """Runs when the worker returns: unlink what it still owns, then release its reservation."""
        assert not self._lock.held()
        failed = []
        for file in ticket.files:
            try:
                self._files.unlink(file)
            except OSError:
                failed.append(file)
        ticket.files.clear()
        with self._lock:
            retained = False
            if failed:
                try:
                    with self._transaction() as db:
                        db.executemany("INSERT OR IGNORE INTO blob_doomed VALUES (?, ?)",
                                       [(file, ticket.size) for file in failed])
                except sqlite3.Error:
                    retained = True
                else:
                    self._doomed += round_up(ticket.size) * len(failed)
                    self._doomed_files += len(failed)
            if not retained:
                self._outstanding -= ticket.reservation
                ticket.reservation = 0
            self._live.discard(ticket)
            ticket.state = "returned"

    def _admit_physical(self, need: int) -> None:
        limits = self.limits
        if self._doomed > limits.doomed_max_bytes or self._doomed_files > limits.doomed_max_files:
            raise BlobCleanupBacklog("blob cleanup backlog")
        if (self._committed + self._doomed + self._outstanding + need + self._database_bytes()
                > limits.max_physical_bytes):
            raise BlobCapacity("blob physical capacity reached")
        if self._files.free_bytes() - self._outstanding - need < limits.disk_reserve_bytes:
            raise BlobCapacity("blob disk reserve reached")

    def _stored_manifest(self, route: bytes, object_: bytes) -> tuple[Manifest, bool]:
        row = self._db.execute("SELECT length, part_hashes, complete FROM blob_objects WHERE route=? AND object=?",
                               (route, object_)).fetchone()
        if row is None:
            raise BlobObjectMissing("blob object missing")
        return Manifest(route, object_, row[0], _hashes(row[1])), bool(row[2])

    def _part_file(self, route: bytes, object_: bytes, index: int) -> str | None:
        row = self._db.execute("SELECT file FROM blob_parts WHERE route=? AND object=? AND idx=?",
                               (route, object_, index)).fetchone()
        return row[0] if row else None

    def _drop_part(self, route: bytes, object_: bytes, index: int, file: str) -> bool:
        """Moves a damaged part row to the doomed ledger. True when the caller now owns its unlink."""
        now = self._clock()
        with self._lock:
            row = self._db.execute("SELECT size FROM blob_parts WHERE route=? AND object=? AND idx=? AND file=?",
                                   (route, object_, index, file)).fetchone()
            if row is None:
                return False
            with self._transaction() as db:
                self._drop_rows(db, [(route, object_, index, file, row[0])], now)
            self._committed -= round_up(row[0])
            self._doomed += round_up(row[0])
            self._doomed_files += 1
            if file in self._cleaning:
                return False
            self._cleaning.add(file)
            return True

    def _drop_rows(self, db: sqlite3.Connection, rows: list[tuple[bytes, bytes, int, str, int]], now: float) -> None:
        for route, object_, index, file, size in rows:
            db.execute("DELETE FROM blob_parts WHERE route=? AND object=? AND idx=?", (route, object_, index))
            db.execute("INSERT OR IGNORE INTO blob_doomed VALUES (?, ?)", (file, size))
            was_complete = db.execute("SELECT complete FROM blob_objects WHERE route=? AND object=?",
                                      (route, object_)).fetchone()
            if was_complete is not None and was_complete[0]:
                db.execute("UPDATE blob_objects SET complete=0, expires_at=? WHERE route=? AND object=?",
                           (now + self.limits.incomplete_seconds, route, object_))
                self._adjust(db, route, 0, 0, 1)

    # Expiry, cleanup and startup

    def expire(self, dead_routes: Iterable[bytes] = ()) -> ExpiryReport:
        """Dooms expired objects and every object of `dead_routes`, in bounded transactions, then unlinks."""
        dead = sorted({identifier(route, "route") for route in dead_routes})
        report = ExpiryReport()
        batch = self.limits.expiry_batch
        while True:
            now = self._clock()
            with self._lock:
                with self._transaction() as db:
                    victims = db.execute("SELECT route, object FROM blob_objects WHERE expires_at<=? LIMIT ?",
                                         (now, batch)).fetchall()
                    for route in dead:
                        if len(victims) >= batch:
                            break
                        victims += db.execute("SELECT route, object FROM blob_objects WHERE route=? LIMIT ?",
                                              (route, batch - len(victims))).fetchall()
                    victims = list(dict.fromkeys(victims))
                    doomed = self._delete_objects(db, victims)
                    wanted = db.execute(
                        "DELETE FROM blob_wanted WHERE rowid IN (SELECT w.rowid FROM blob_wanted w LEFT JOIN blob_objects o "
                        "ON o.route=w.route AND o.object=w.object WHERE w.wanted_at<=? OR o.complete=1 LIMIT ?)",
                        (now - self.limits.wanted_seconds, batch)).rowcount
                    if not victims and dead:
                        wanted += db.execute(
                            f"DELETE FROM blob_wanted WHERE rowid IN (SELECT rowid FROM blob_wanted WHERE route IN "
                            f"({','.join('?' * len(dead))}) LIMIT ?)", (*dead, batch)).rowcount
                self._committed -= sum(round_up(size) for size in doomed)
                self._doomed += sum(round_up(size) for size in doomed)
                self._doomed_files += len(doomed)
            report.objects += len(victims)
            report.parts += len(doomed)
            report.wanted += wanted
            if not victims and wanted < batch:
                break
        unlinked, failed = self.cleanup()
        report.unlinked, report.failed_unlinks = unlinked, failed
        return report

    def _delete_objects(self, db: sqlite3.Connection, victims: list[tuple[bytes, bytes]]) -> list[int]:
        doomed = []
        for route, object_ in victims:
            length, complete = db.execute("SELECT length, complete FROM blob_objects WHERE route=? AND object=?",
                                          (route, object_)).fetchone()
            for file, size in db.execute("SELECT file, size FROM blob_parts WHERE route=? AND object=?",
                                         (route, object_)).fetchall():
                db.execute("INSERT OR IGNORE INTO blob_doomed VALUES (?, ?)", (file, size))
                doomed.append(size)
            db.execute("DELETE FROM blob_parts WHERE route=? AND object=?", (route, object_))
            db.execute("DELETE FROM blob_wanted WHERE route=? AND object=?", (route, object_))
            db.execute("DELETE FROM blob_objects WHERE route=? AND object=?", (route, object_))
            self._adjust(db, route, -length, -1, 0 if complete else -1)
        return doomed

    def cleanup(self) -> tuple[int, int]:
        """Unlinks doomed files one at a time outside the lock. Bytes leave the ledger only after unlink."""
        unlinked = failed = 0
        attempted: set[str] = set()
        while True:
            with self._lock:
                rows = []
                for file, size in self._db.execute("SELECT file, size FROM blob_doomed ORDER BY file"):
                    if file not in attempted and file not in self._cleaning:
                        rows.append((file, size))
                        if len(rows) == self.limits.cleanup_batch:
                            break
                self._cleaning.update(file for file, _ in rows)
            if not rows:
                return unlinked, failed
            attempted.update(file for file, _ in rows)
            done, refused = self._unlink_doomed(rows)
            unlinked += done
            failed += refused

    def _unlink_doomed(self, rows: list[tuple[str, int]]) -> tuple[int, int]:
        """Unlinks rows the caller marked in `_cleaning`, then deletes their rows and ledger bytes once."""
        done, failed = [], 0
        try:
            for file, size in rows:
                try:
                    self._files.unlink(file)
                except OSError:
                    failed += 1
                else:
                    done.append((file, size))
        finally:
            with self._lock:
                try:
                    if done:
                        removed = []
                        with self._transaction() as db:
                            for file, size in done:
                                if db.execute("DELETE FROM blob_doomed WHERE file=?", (file,)).rowcount:
                                    removed.append(size)
                        self._doomed -= sum(round_up(size) for size in removed)
                        self._doomed_files -= len(removed)
                finally:
                    self._cleaning.difference_update(file for file, _ in rows)
        return len(done), failed

    def _reconcile(self) -> None:
        report = self.startup
        report.temporary_removed, unexpected = self._files.clear_temp()
        report.unexpected += unexpected
        with self._lock:
            parts = self._db.execute("SELECT route, object, idx, file, size FROM blob_parts").fetchall()
            referenced = {row[3] for row in parts}
            referenced.update(row[0] for row in self._db.execute("SELECT file FROM blob_doomed"))
        damaged = [row for row in parts if self._files.size(row[3]) != row[4]]
        batch = self.limits.cleanup_batch
        for start in range(0, len(damaged), batch):
            with self._lock, self._transaction() as db:
                self._drop_rows(db, damaged[start:start + batch], self._clock())
        report.rows_dropped = len(damaged)
        for directory, name in self._files.scan():
            file = f"{directory}/{name}"
            if not directory or not _PART_NAME.fullmatch(name) or file in referenced:
                if not directory or not _PART_NAME.fullmatch(name):
                    report.unexpected.append(file.lstrip("/"))
                continue
            try:
                self._files.unlink(file)
            except OSError:
                report.unexpected.append(file)
            else:
                report.unreferenced_removed += 1
        with self._lock:
            self._committed = sum(round_up(row[0]) for row in self._db.execute("SELECT size FROM blob_parts"))
            doomed = self._db.execute("SELECT size FROM blob_doomed").fetchall()
            self._doomed = sum(round_up(row[0]) for row in doomed)
            self._doomed_files = len(doomed)
        report.doomed_finished, _ = self.cleanup()

    def close(self) -> None:
        with self._lock:
            if self._live:
                raise RuntimeError("blob tickets are still owned by workers")
        self._files.close()
        self._db.close()


async def run_blob_worker(
    store: BlobStore, ticket: BlobTicket, work: Callable[[], Any], *, executor: Executor, timeout: float,
    on_return: Callable[[], None] | None = None,
) -> Any:
    """Runs `work` for `ticket` on `executor` with a response deadline.

    The deadline or task cancellation only cancels the ticket. The ticket's
    files and reservation are released by the worker itself, and `on_return`
    (for the caller's permits) is scheduled on the loop only after the
    executor function has returned.
    """
    loop = asyncio.get_running_loop()

    def owned() -> Any:
        try:
            return work()
        finally:
            if on_return is not None:
                try:
                    loop.call_soon_threadsafe(on_return)
                except RuntimeError:
                    on_return()

    future = loop.run_in_executor(executor, owned)
    future.add_done_callback(lambda done: done.cancelled() or done.exception())
    try:
        return await asyncio.wait_for(asyncio.shield(future), timeout)
    except TimeoutError:
        store.cancel(ticket)
        raise BlobDeadline() from None
    except asyncio.CancelledError:
        store.cancel(ticket)
        raise


def _usage(db: sqlite3.Connection, scope: bytes) -> tuple[int, int, int]:
    row = db.execute("SELECT logical_bytes, objects, incomplete FROM blob_usage WHERE scope=?", (scope,)).fetchone()
    return tuple(row) if row else (0, 0, 0)


def _present(db: sqlite3.Connection, route: bytes, object_: bytes) -> list[int]:
    return [row[0] for row in db.execute("SELECT idx FROM blob_parts WHERE route=? AND object=? ORDER BY idx",
                                         (route, object_))]


def _hashes(packed: bytes) -> tuple[bytes, ...]:
    return tuple(packed[offset:offset + ID_BYTES] for offset in range(0, len(packed), ID_BYTES))


def _schema(db: sqlite3.Connection) -> list[tuple[Any, ...]]:
    return db.execute("SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name").fetchall()


_EXPECTED_SCHEMA: list[tuple[Any, ...]] | None = None


def _expected_schema() -> list[tuple[Any, ...]]:
    global _EXPECTED_SCHEMA
    if _EXPECTED_SCHEMA is None:
        db = sqlite3.connect(":memory:")
        try:
            db.executescript(SCHEMA)
            _EXPECTED_SCHEMA = _schema(db)
        finally:
            db.close()
    return _EXPECTED_SCHEMA


def _validate_contents(db: sqlite3.Connection) -> None:
    def corrupt(reason: str) -> BlobStoreCorrupt:
        return BlobStoreCorrupt(f"blob database inconsistent: {reason}")

    usage: dict[bytes, list[int]] = {GLOBAL_SCOPE: [0, 0, 0]}
    objects: dict[tuple[bytes, bytes], tuple[Manifest, int]] = {}
    for (route, object_, length, parts, hashes, complete, created, touched, expires, released, lease_writer,
         lease_until, creator) in db.execute("SELECT * FROM blob_objects"):
        try:
            manifest = Manifest.validated(route, object_, length, _hashes(hashes) if type(hashes) is bytes else None)
            identifier(creator, "creator")
            if lease_writer is not None:
                identifier(lease_writer, "lease")
        except RequestError as error:
            raise corrupt(f"object row: {error}") from None
        if (parts != manifest.parts or len(hashes) != ID_BYTES * parts or complete not in (0, 1)
                or released not in (0, 1) or (lease_writer is None) != (lease_until is None)
                or not all(math.isfinite(value) for value in (created, touched, expires))):
            raise corrupt("object row fields")
        objects[(route, object_)] = (manifest, complete)
        for scope in (route, GLOBAL_SCOPE):
            totals = usage.setdefault(scope, [0, 0, 0])
            totals[0] += length
            totals[1] += 1
            totals[2] += 1 - complete
    present: dict[tuple[bytes, bytes], int] = {}
    for route, object_, index, file, size, _created in db.execute("SELECT * FROM blob_parts"):
        entry = objects.get((route, object_))
        if entry is None or type(index) is not int or not 0 <= index < entry[0].parts:
            raise corrupt("part without object")
        match = _PART_NAME.fullmatch(file.partition("/")[2]) if type(file) is str else None
        if (match is None or file.partition("/")[0] != route.hex() or match.group(1) != object_.hex()
                or int(match.group(2)) != index or size != entry[0].part_bytes(index)):
            raise corrupt("part row fields")
        present[(route, object_)] = present.get((route, object_), 0) + 1
    for key, (manifest, complete) in objects.items():
        if complete != (present.get(key, 0) == manifest.parts):
            raise corrupt("completion flag")
    for file, size in db.execute("SELECT * FROM blob_doomed"):
        try:
            _split(file)
        except (ValueError, AttributeError):
            raise corrupt("doomed file name") from None
        if type(size) is not int or not 1 <= size <= PART_BYTES:
            raise corrupt("doomed size")
    for route, object_, _wanted_at in db.execute("SELECT * FROM blob_wanted"):
        if type(route) is not bytes or len(route) != ID_BYTES or type(object_) is not bytes or len(object_) != ID_BYTES:
            raise corrupt("wanted row")
    stored = {row[0]: list(row[1:]) for row in db.execute("SELECT * FROM blob_usage")}
    if stored != usage:
        raise corrupt("usage counters")
