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
import functools
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
from concurrent.futures import Executor, Future
from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, NamedTuple
from urllib.parse import quote

from .blob_format import ID_BYTES, Manifest, identifier
from .http import RequestError

FORMAT_VERSION = 1
APPLICATION_ID = 0x47534231
GLOBAL_SCOPE = b"\x00"
BLOCK_BYTES = 4096
PAGE_BYTES = 4096
MAX_SECTOR_BYTES = 65_536
SUPPORTED_TEMP_STORE = frozenset({"TEMP_STORE=1", "TEMP_STORE=2", "TEMP_STORE=3"})
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


class BlobStoreCapacity(BlobStoreError):
    """A new store would not fit its metadata reservation within the physical budget or disk reserve."""


def round_up(size: int) -> int:
    return -(-size // BLOCK_BYTES) * BLOCK_BYTES


def metadata_reservation(pages: int) -> int:
    """Physical bytes reserved for a database of at most `pages` pages and one rollback journal.

    A rollback journal holds one sector-padded header (sector size at most 65,536) and at most one
    `page + 8` byte record per page that existed when the transaction began. With `cache_spill=OFF`
    there is no mid-transaction journal sync, so no second segment header.
    """
    return pages * PAGE_BYTES + round_up(MAX_SECTOR_BYTES + pages * (PAGE_BYTES + 8))


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
    metadata_database_bytes: int = 160 * 1024**2
    metadata_emergency_bytes: int = 4 * 1024**2
    global_wanted: int = 8_192
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
        if (self.metadata_database_bytes % PAGE_BYTES or self.metadata_emergency_bytes % PAGE_BYTES
                or not self.metadata_emergency_bytes < self.metadata_database_bytes):
            raise ValueError("metadata limits must be page multiples with the emergency reserve below the ceiling")


_INTEGER_LIMITS = {
    "group_logical_bytes", "group_objects", "group_incomplete", "writer_incomplete", "global_logical_bytes",
    "global_objects", "global_incomplete", "max_physical_bytes", "disk_reserve_bytes", "doomed_max_bytes",
    "doomed_max_files", "metadata_database_bytes", "metadata_emergency_bytes", "global_wanted", "wanted_per_group",
    "objects_per_request", "expiry_batch", "cleanup_batch",
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
            self.reading(descriptor)
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

    def reading(self, descriptor: int) -> None:
        """Called with the open part descriptor before it is read; a test seam."""

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

    def status(self, file: str) -> tuple[str, int] | None:
        """`("file", size)`, `("link", 0)` or `("other", 0)` for a `route/name` or `tmp/name` entry; None when absent."""
        self._unlocked()
        directory_name, name = _split(file)
        temporary = directory_name == TEMP_DIRECTORY
        try:
            directory = self._temp if temporary else self._route_directory(directory_name, create=False)
        except OSError:
            return None
        try:
            status = os.stat(name, dir_fd=directory, follow_symlinks=False)
        except FileNotFoundError:
            return None
        finally:
            if not temporary:
                os.close(directory)
        if stat.S_ISREG(status.st_mode):
            return "file", status.st_size
        return ("link" if stat.S_ISLNK(status.st_mode) else "other"), 0

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
        self.pinned = False
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
    deferred: int = 0
    errors: int = 0


@dataclass
class StartupReport:
    recovered_journal: bool = False
    temporary_removed: int = 0
    rows_dropped: int = 0
    orphans_doomed: int = 0
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
        self._temp_store_always_memory = _supported_sqlite_build()
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
        self._readers: dict[str, int] = {}
        self._debt: dict[str, tuple[int, int]] = {}
        self._pages = {False: 0, True: 0}
        self.touch_refused = 0
        try:
            with self._lock:
                self._set_ceiling(ownership=True)
                self._set_ceiling(ownership=False)
            self._reconcile()
        except sqlite3.Error as error:
            self._files.close()
            self._db.close()
            failure = BlobStoreCapacity if _full(error) else BlobStoreCorrupt
            raise failure(f"blob startup reconciliation failed: {error}") from error
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
            self._admit_creation(path)
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
            self._configure_database(db)
        except sqlite3.Error as error:
            db.close()
            raise BlobStoreCorrupt(f"blob database unreadable: {error}") from error
        except BaseException:
            db.close()
            raise
        return db

    def _admit_creation(self, path: Path) -> None:
        reserved = metadata_reservation(self.limits.metadata_database_bytes // PAGE_BYTES)
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        status = os.statvfs(path.parent)
        if (reserved > self.limits.max_physical_bytes
                or status.f_bavail * status.f_frsize - reserved < self.limits.disk_reserve_bytes):
            raise BlobStoreCapacity("no physical capacity or disk reserve for a new blob store")

    def _verify_settings(self, db: sqlite3.Connection) -> None:
        expected = {"journal_mode": "delete", "synchronous": 2, "fullfsync": 1, "secure_delete": 1, "cache_spill": 0,
                    "page_size": PAGE_BYTES}
        for name, value in expected.items():
            actual = db.execute(f"PRAGMA {name}").fetchone()[0]
            if actual != value:
                raise BlobStoreUnsupported(f"unsupported blob database setting {name}={actual}")
        if db.execute("PRAGMA temp_store").fetchone()[0] != 2 and not self._temp_store_always_memory:
            raise BlobStoreUnsupported("SQLite did not accept in-memory temporary storage")
        if [row[1] for row in db.execute("PRAGMA database_list")] != ["main"]:
            raise BlobStoreUnsupported("blob database connection has attached databases")

    def _configure_database(self, db: sqlite3.Connection) -> None:
        for pragma in ("journal_mode=DELETE", "synchronous=FULL", "fullfsync=ON", "secure_delete=ON",
                       "foreign_keys=OFF", "cache_spill=OFF", "temp_store=MEMORY"):
            db.execute(f"PRAGMA {pragma}")
        self._verify_settings(db)

    def _create_database(self, path: Path) -> None:
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        staging = Path(f"{path}.creating")
        for leftover in (staging, Path(f"{staging}-journal")):
            if leftover.is_symlink() or leftover.exists():
                leftover.unlink()
        os.close(os.open(staging, os.O_CREAT | os.O_EXCL | os.O_RDWR | os.O_NOFOLLOW, 0o600))
        try:
            db = sqlite3.connect(staging, isolation_level=None)
            try:
                db.execute(f"PRAGMA page_size = {PAGE_BYTES}")
                pages = self.limits.metadata_database_bytes // PAGE_BYTES
                if db.execute(f"PRAGMA max_page_count = {pages}").fetchone()[0] != pages:
                    raise BlobStoreCapacity("fresh blob metadata ceiling unavailable")
                self._configure_database(db)
                db.executescript(SCHEMA)
                db.execute("INSERT INTO blob_usage VALUES (?, 0, 0, 0)", (GLOBAL_SCOPE,))
                db.execute(f"PRAGMA application_id = {APPLICATION_ID}")
                db.execute(f"PRAGMA user_version = {FORMAT_VERSION}")
                if db.execute("PRAGMA page_count").fetchone()[0] > pages:
                    raise BlobStoreCapacity("fresh blob metadata ceiling exceeded")
            finally:
                db.close()
        except BaseException as error:
            for leftover in (staging, Path(f"{staging}-journal")):
                leftover.unlink(missing_ok=True)
            if isinstance(error, sqlite3.Error) and _full(error):
                raise BlobStoreCapacity("fresh blob metadata ceiling reached") from error
            raise
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
            page_size = db.execute("PRAGMA page_size").fetchone()[0]
            if page_size != PAGE_BYTES:
                raise BlobStoreUnsupported(f"unsupported blob database page size {page_size}")
            if db.execute("PRAGMA quick_check").fetchall() != [("ok",)]:
                raise BlobStoreCorrupt("blob database failed quick_check")
            if _schema(db) != _expected_schema():
                raise BlobStoreCorrupt("unexpected blob database schema")
            _validate_contents(db)
        finally:
            if db.in_transaction:
                db.execute("ROLLBACK")

    # Ledgers and transactions

    def _set_ceiling(self, *, ownership: bool) -> int:
        """Sets SQLite's page ceiling for the next transaction and returns the effective value.

        Ordinary transactions stop `metadata_emergency_bytes` below `metadata_database_bytes`; ownership
        transactions may use the rest. SQLite never lowers the ceiling below the current page count, so a file
        already past a boundary can only reuse its free pages.
        """
        limit = self.limits.metadata_database_bytes // PAGE_BYTES
        if not ownership:
            limit -= self.limits.metadata_emergency_bytes // PAGE_BYTES
        effective = self._db.execute(f"PRAGMA max_page_count = {limit}").fetchone()[0]
        self._pages[ownership] = effective
        return effective

    @contextmanager
    def _transaction(self, *, ownership: bool = False) -> Iterator[sqlite3.Connection]:
        """One write transaction. An ordinary transaction that hits its page ceiling raises `BlobCapacity`."""
        assert self._lock.held()
        try:
            self._set_ceiling(ownership=ownership)
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
        except sqlite3.Error as error:
            if not ownership and _full(error):
                raise BlobCapacity("blob metadata ceiling reached") from error
            raise
        finally:
            if ownership:
                self._set_ceiling(ownership=False)

    @contextmanager
    def _metadata_transaction(self) -> Iterator[sqlite3.Connection]:
        self._admit_metadata()
        with self._transaction() as db:
            yield db

    def _metadata_reserved(self) -> int:
        pages = self._db.execute("PRAGMA page_count").fetchone()[0]
        return metadata_reservation(max(self.limits.metadata_database_bytes // PAGE_BYTES, pages))

    def ledger(self) -> dict[str, int]:
        with self._lock:
            return {
                "committed": self._committed, "doomed": self._doomed, "doomedFiles": self._doomed_files,
                "outstanding": self._outstanding, "database": self._metadata_reserved(),
                "databaseFile": self._database_path.stat().st_size, "journalPeak": self._journal_peak,
                "liveTickets": len(self._live), "pinnedFiles": len(self._readers), "debtFiles": len(self._debt),
                "ordinaryPages": self._pages[False], "ownershipPages": self._pages[True],
                "touchRefused": self.touch_refused,
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
        with self._lock, self._metadata_transaction() as db:
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
        """Records or refreshes wanted objects, all or nothing. Complete objects are skipped."""
        route = identifier(route, "route")
        objects = self._object_list(objects)
        now = self._clock()
        with self._lock, self._metadata_transaction() as db:
            fresh, refresh = [], []
            for object_ in objects:
                complete = db.execute("SELECT complete FROM blob_objects WHERE route=? AND object=?",
                                      (route, object_)).fetchone()
                if complete is not None and complete[0]:
                    continue
                exists = db.execute("SELECT 1 FROM blob_wanted WHERE route=? AND object=?", (route, object_)).fetchone()
                (refresh if exists else fresh).append(object_)
            if fresh:
                if (db.execute("SELECT COUNT(*) FROM blob_wanted WHERE route=?", (route,)).fetchone()[0] + len(fresh)
                        > self.limits.wanted_per_group):
                    raise BlobGroupQuota("blob wanted list full")
                if db.execute("SELECT COUNT(*) FROM blob_wanted").fetchone()[0] + len(fresh) > self.limits.global_wanted:
                    raise BlobCapacity("blob wanted capacity reached")
            for object_ in fresh + refresh:
                db.execute("INSERT INTO blob_wanted VALUES (?, ?, ?) ON CONFLICT(route, object) DO UPDATE "
                           "SET wanted_at=excluded.wanted_at", (route, object_, now))
            return len(fresh) + len(refresh)

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
        with self._lock, self._metadata_transaction() as db:
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
            self._readers[file] = self._readers.get(file, 0) + 1
            ticket.pinned = True
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
                status = self._files.status(ticket.file)
                owned = ticket.size if status is not None and status[0] == "other" else _owned_bytes(ticket.file, status)
                self._drop_part(ticket.route, ticket.object, ticket.index, ticket.file, owned)
                raise BlobPartMissing("blob part missing")
            now = self._clock()
            with self._lock:
                if ticket.state == "cancelled":
                    raise BlobCancelled()
                row = self._db.execute("SELECT complete, touched_at, released FROM blob_objects WHERE route=? AND object=?",
                                       (ticket.route, ticket.object)).fetchone()
                if row is not None and row[0] and (row[2] or now - row[1] >= self.limits.touch_resolution_seconds):
                    try:
                        with self._metadata_transaction() as db:
                            self._touch(db, ticket.route, ticket.object, now, row[1], row[2])
                    except BlobCapacity:
                        self.touch_refused += 1
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
        if not self._release_unstarted(ticket):
            raise RuntimeError("ticket worker already started")

    def _release_unstarted(self, ticket: BlobTicket) -> bool:
        """Disposes `ticket` if no store worker ever started it. The caller guarantees none can start later."""
        with self._lock:
            if ticket.started:
                return False
            ticket.started = True
            ticket.state = "cancelled"
        self._dispose(ticket)
        return True

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
        """Runs when the worker returns: unlink what it still owns, release its reservation and its read pin.

        A file that cannot be unlinked or recorded as doomed becomes ownership debt: it keeps its reservation
        and blocks ordinary admission until `cleanup` unlinks or records it. The last reader of a doomed file
        unlinks it here, once, after the lock is released.
        """
        assert not self._lock.held()
        failed = []
        for file in ticket.files:
            try:
                self._files.unlink(file)
            except OSError:
                failed.append(file)
        ticket.files.clear()
        last_reader = None
        with self._lock:
            if failed:
                try:
                    with self._transaction(ownership=True) as db:
                        db.executemany("INSERT OR IGNORE INTO blob_doomed VALUES (?, ?)",
                                       [(file, ticket.size) for file in failed])
                except sqlite3.Error:
                    for position, file in enumerate(failed):
                        self._debt[file] = (ticket.size, ticket.reservation if position == 0 else 0)
                    ticket.reservation = 0
                else:
                    self._doomed += round_up(ticket.size) * len(failed)
                    self._doomed_files += len(failed)
            self._outstanding -= ticket.reservation
            ticket.reservation = 0
            if ticket.pinned:
                ticket.pinned = False
                last_reader = self._unpin(ticket.file)
            self._live.discard(ticket)
            ticket.state = "returned"
        if last_reader is not None:
            self._unlink_doomed([last_reader])

    def _unpin(self, file: str) -> tuple[str, int] | None:
        """Drops one read pin. Returns the doomed row the caller must unlink when this was the last reader."""
        count = self._readers[file] - 1
        if count:
            self._readers[file] = count
            return None
        del self._readers[file]
        row = self._db.execute("SELECT size FROM blob_doomed WHERE file=?", (file,)).fetchone()
        if row is None or file in self._cleaning:
            return None
        self._cleaning.add(file)
        return file, row[0]

    def _admit_physical(self, need: int) -> None:
        limits = self.limits
        if self._doomed > limits.doomed_max_bytes or self._doomed_files > limits.doomed_max_files:
            raise BlobCleanupBacklog("blob cleanup backlog")
        self._admit_metadata(need)

    def _admit_metadata(self, need: int = 0) -> None:
        """Ordinary admission: no ownership debt, the full metadata reservation and `need` fit the physical
        budget, and the unallocated reservation and `need` leave the disk reserve free."""
        limits = self.limits
        if self._debt:
            raise BlobCapacity("blob ownership debt pending")
        reserved = self._metadata_reserved()
        if self._committed + self._doomed + self._outstanding + reserved + need > limits.max_physical_bytes:
            raise BlobCapacity("blob physical capacity reached")
        unallocated = reserved - self._database_path.stat().st_size
        if self._files.free_bytes() - self._outstanding - need - unallocated < limits.disk_reserve_bytes:
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

    def _drop_part(self, route: bytes, object_: bytes, index: int, file: str, owned: int) -> None:
        """Moves a damaged part row to the doomed ledger at `owned` bytes; its last reader unlinks it.

        If the ownership write fails, the row and its charge stay and a later read retries.
        """
        now = self._clock()
        with self._lock:
            row = self._db.execute("SELECT size FROM blob_parts WHERE route=? AND object=? AND idx=? AND file=?",
                                   (route, object_, index, file)).fetchone()
            if row is None:
                return
            try:
                with self._transaction(ownership=True) as db:
                    self._drop_rows(db, [(route, object_, index, file, owned)], now)
            except sqlite3.Error:
                return
            self._committed -= round_up(row[0])
            self._doomed += round_up(owned)
            self._doomed_files += 1

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
        """Dooms expired objects and every object of `dead_routes`, in bounded ownership transactions, then unlinks.

        A batch whose transaction fails is rolled back, counted in `errors` and retried by the next call.
        """
        dead = sorted({identifier(route, "route") for route in dead_routes})
        report = ExpiryReport()
        while True:
            try:
                victims, parts, wanted = self._expire_batch(dead)
            except sqlite3.Error:
                report.errors += 1
                break
            report.objects += victims
            report.parts += parts
            report.wanted += wanted
            if not victims and wanted < self.limits.expiry_batch:
                break
        unlinked, failed = self.cleanup()
        report.unlinked, report.failed_unlinks = unlinked, failed
        with self._lock:
            report.deferred = sum(1 for file in self._readers
                                  if self._db.execute("SELECT 1 FROM blob_doomed WHERE file=?", (file,)).fetchone())
        return report

    def _expire_batch(self, dead: list[bytes]) -> tuple[int, int, int]:
        now = self._clock()
        batch = self.limits.expiry_batch
        with self._lock:
            with self._transaction(ownership=True) as db:
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
        return len(victims), len(doomed), wanted

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
        self._retry_debt()
        unlinked = failed = 0
        attempted: set[str] = set()
        while True:
            with self._lock:
                rows = []
                for file, size in self._db.execute("SELECT file, size FROM blob_doomed ORDER BY file"):
                    if file not in attempted and file not in self._cleaning and file not in self._readers:
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

    def _retry_debt(self) -> None:
        """Retries ownership debt: unlink each file, or record it as doomed; only then release its reservation."""
        with self._lock:
            debts = list(self._debt.items())
        for file, (size, reservation) in debts:
            try:
                self._files.unlink(file)
                removed = True
            except OSError:
                removed = False
            with self._lock:
                if file not in self._debt:
                    continue
                if not removed:
                    try:
                        with self._transaction(ownership=True) as db:
                            db.execute("INSERT OR IGNORE INTO blob_doomed VALUES (?, ?)", (file, size))
                    except sqlite3.Error:
                        continue
                    self._doomed += round_up(size)
                    self._doomed_files += 1
                del self._debt[file]
                self._outstanding -= reservation

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
                        try:
                            with self._transaction(ownership=True) as db:
                                for file, size in done:
                                    if db.execute("DELETE FROM blob_doomed WHERE file=?", (file,)).rowcount:
                                        removed.append(size)
                        except sqlite3.Error:
                            removed = []
                        self._doomed -= sum(round_up(size) for size in removed)
                        self._doomed_files -= len(removed)
                finally:
                    self._cleaning.difference_update(file for file, _ in rows)
        return len(done), failed

    def _reconcile(self) -> None:
        """Startup: inspect every owned path first, then clear temporaries, doom and recount at actual size, rebuild.

        Every store-owned byte found on disk is recorded in `blob_doomed` at its actual size before any unlink,
        so an unlink that fails keeps counting until a later cleanup succeeds. A part, doomed or canonical path
        that is neither a regular file nor a link fails the open before any metadata or file changes.
        """
        report = self.startup
        with self._lock:
            parts = self._db.execute("SELECT route, object, idx, file, size FROM blob_parts").fetchall()
            doomed = self._db.execute("SELECT file, size FROM blob_doomed").fetchall()
        referenced = {row[3] for row in parts} | {file for file, _ in doomed}
        damaged = []
        for route, object_, index, file, size in parts:
            status = self._files.status(file)
            if status != ("file", size):
                damaged.append((route, object_, index, file, _owned_bytes(file, status)))
        recount = []
        for file, size in doomed:
            actual = _owned_bytes(file, self._files.status(file))
            if actual != size:
                recount.append((actual, file))
        orphans = []
        for directory, name in self._files.scan():
            file = f"{directory}/{name}"
            if not directory or not _PART_NAME.fullmatch(name):
                report.unexpected.append(file.lstrip("/"))
            elif file not in referenced:
                orphans.append((file, _owned_bytes(file, self._files.status(file))))
        report.temporary_removed, unexpected = self._files.clear_temp()
        report.unexpected += unexpected
        batch = self.limits.cleanup_batch
        for start in range(0, len(damaged), batch):
            with self._lock, self._transaction(ownership=True) as db:
                self._drop_rows(db, damaged[start:start + batch], self._clock())
        for start in range(0, len(recount), batch):
            with self._lock, self._transaction(ownership=True) as db:
                db.executemany("UPDATE blob_doomed SET size=? WHERE file=?", recount[start:start + batch])
        for start in range(0, len(orphans), batch):
            with self._lock, self._transaction(ownership=True) as db:
                db.executemany("INSERT OR IGNORE INTO blob_doomed VALUES (?, ?)", orphans[start:start + batch])
        report.rows_dropped, report.orphans_doomed = len(damaged), len(orphans)
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


Offload = Callable[[Callable[[], None], bool], None]
"""Runs a store-touching callable off the event loop. With `required` true the offload owner must run it once or
retain it; with `required` false (a cancellation request) it may drop it."""


class _Handoff:
    """Entry gate for one submitted blob job.

    The state moves once, under `_lock`, from `pending` to `entered` (the submitted function took the work) or
    to `closed` (it never will). Only winning `pending -> closed` proves non-entry and allows settling here;
    entered work settles itself after it returns. Settling runs `release_unstarted` (if any) and calls
    `on_return` at most once. A failing `on_return` is reported to the loop's exception handler and changes
    nothing else. With `offload`, settling never runs `release_unstarted` on the event loop thread.
    """

    def __init__(self, release_unstarted: Callable[[], None] | None, work: Callable[[], Any],
                 on_return: Callable[[], None] | None, loop: asyncio.AbstractEventLoop,
                 offload: Offload | None = None) -> None:
        self._lock = threading.Lock()
        self._state = "pending"
        self._settled = False
        self._work: Callable[[], Any] | None = work
        self._release: Callable[[], None] | None = release_unstarted
        self._on_return = on_return
        self._loop = loop
        self._offload = offload
        self._loop_thread = threading.get_ident()
        self.done: asyncio.Future[Any] = loop.create_future()
        self.done.add_done_callback(lambda done: done.cancelled() or done.exception())

    def run(self) -> None:
        with self._lock:
            if self._state != "pending":
                return
            self._state = "entered"
            work, self._work = self._work, None
        result: Any = None
        error: BaseException | None = None
        try:
            result = work()
        except BaseException as caught:
            error = caught
        finally:
            del work
            try:
                self._settle(on_loop=False)
            finally:
                self._deliver(result, error)

    def close(self) -> bool:
        with self._lock:
            if self._state != "pending":
                return False
            self._state = "closed"
            self._work = None
        return True

    def close_and_settle(self, *, on_loop: bool, error: BaseException | None = None) -> bool:
        if not self.close():
            return False
        try:
            if self._offload is not None and self._release is not None and threading.get_ident() == self._loop_thread:
                self._offload(lambda: self._settle(on_loop=False), True)
            else:
                self._settle(on_loop=on_loop)
        finally:
            if error is not None:
                self._deliver(None, error)
        return True

    def finished(self, future: Future[Any]) -> None:
        """Executor future callback: a job that ended without entering is settled here."""
        if future.cancelled():
            error: BaseException = BlobCancelled()
        else:
            error = future.exception() or BlobCancelled()
        self.close_and_settle(on_loop=False, error=error)

    def _settle(self, *, on_loop: bool) -> None:
        with self._lock:
            if self._settled:
                return
            self._settled = True
            release, on_return = self._release, self._on_return
            self._release = self._on_return = None
        try:
            if release is not None:
                release()
        finally:
            if on_return is not None:
                self._call(on_return, on_loop=on_loop)

    def _call(self, on_return: Callable[[], None], *, on_loop: bool) -> None:
        loop = self._loop

        def guarded() -> None:
            try:
                on_return()
            except Exception as error:
                if not loop.is_closed():
                    loop.call_exception_handler({"message": "blob on_return failed", "exception": error})

        if on_loop:
            guarded()
            return
        try:
            loop.call_soon_threadsafe(guarded)
        except RuntimeError:
            guarded()

    def _deliver(self, result: Any, error: BaseException | None) -> None:
        def publish() -> None:
            if self.done.done():
                return
            if error is None:
                self.done.set_result(result)
            else:
                self.done.set_exception(error)

        try:
            self._loop.call_soon_threadsafe(publish)
        except RuntimeError:
            pass


async def run_blob_worker(
    store: BlobStore, ticket: BlobTicket, work: Callable[[], Any], *, executor: Executor, timeout: float,
    on_return: Callable[[], None] | None = None, offload: Offload | None = None,
) -> Any:
    """Runs `work` for an admitted `ticket` on `executor` with a response deadline.

    `work` must synchronously call exactly one of `put_part(ticket, ...)` or `get_part(ticket)`. The call hands
    `work`, the ticket and the caller's permits (`on_return`) to a `_Handoff` gate and keeps no other reference
    to `work`. Outcomes:

    - the job enters: it owns body, files, reservation and permits until `work` returns, then settles and
      delivers its result, even when `submit` raised after queuing it;
    - `submit` raises and the gate closes: no work can run; settled here, then the error is raised;
    - the executor future ends without entry (cancelled, initializer failure): settled by its callback, and
      the awaiter gets `BlobCancelled` or that exception;
    - deadline or task cancellation: the ticket is cancelled and a still-pending job is closed and settled
      at once; an entered job keeps everything until it returns.

    Without `offload` the cancellation and the unstarted release run on the event loop, as before. With
    `offload` the loop only closes the gate: a proven non-entry is settled through `offload(..., True)`, and
    an entered job receives `store.cancel(ticket)` through `offload(..., False)`. A cancellation that reaches
    the store after the worker committed loses: that outcome is committed and uncertain to the client.
    """
    loop = asyncio.get_running_loop()
    handoff = _Handoff(functools.partial(store._release_unstarted, ticket), work, on_return, loop, offload)
    del work, on_return
    submitted: Future[Any] | None
    try:
        submitted = executor.submit(handoff.run)
    except BaseException:
        if handoff.close_and_settle(on_loop=True):
            raise
        submitted = None
    if submitted is not None:
        submitted.add_done_callback(handoff.finished)
    try:
        return await asyncio.wait_for(asyncio.shield(handoff.done), timeout)
    except TimeoutError:
        _cancel(store, ticket, handoff, submitted, offload)
        raise BlobDeadline() from None
    except asyncio.CancelledError:
        _cancel(store, ticket, handoff, submitted, offload)
        raise


def _cancel(store: BlobStore, ticket: BlobTicket, handoff: _Handoff, submitted: Future[Any] | None,
            offload: Offload | None) -> None:
    if offload is None:
        store.cancel(ticket)
        handoff.close_and_settle(on_loop=True)
        if submitted is not None:
            submitted.cancel()
        return
    if not handoff.close_and_settle(on_loop=True):
        offload(functools.partial(store.cancel, ticket), False)


class _OwnedHandoff(_Handoff):
    """Entry gate plus a result slot: a resource-bearing result always has exactly one owner.

    `delivered` results belong to the slot until the waiter adopts them or departs. A departed waiter's result is
    disposed off the event loop (by the job itself, or through `offload(..., True)`); the job's holds
    (`on_return`) are released only after that disposal returns. A failing disposal keeps its holds: in the job's
    own thread it is passed to `retain`; through `offload` the exception reaches the offload owner.
    """

    def __init__(self, work: Callable[[], Any], dispose: Callable[[Any], None] | None,
                 retain: Callable[[Any, BaseException], None] | None, on_return: Callable[[], None] | None,
                 loop: asyncio.AbstractEventLoop, offload: Offload) -> None:
        super().__init__(None, work, on_return, loop, offload)
        self._dispose = dispose
        self._retain = retain
        self._slot = "none"
        self._result: Any = None
        self._departed = False

    def run(self) -> None:
        with self._lock:
            if self._state != "pending":
                return
            self._state = "entered"
            work, self._work = self._work, None
        result: Any = None
        error: BaseException | None = None
        try:
            result = work()
        except BaseException as caught:
            error = caught
        finally:
            del work
        if error is not None:
            with self._lock:
                self._slot = "failed"
            try:
                self._settle(on_loop=False)
            finally:
                self._deliver(None, error)
            return
        with self._lock:
            departed = self._departed
            if not departed:
                self._slot, self._result = "delivered", result
        if departed:
            try:
                self._dispose_and_settle(result)
            except BaseException as error:
                if self._retain is not None:
                    self._retain(result, error)
            return
        self._deliver(result, None)

    def adopt(self) -> Any:
        """Takes the delivered result for the waiter and releases the job's holds."""
        with self._lock:
            if self._slot != "delivered":
                raise RuntimeError("no delivered result to adopt")
            self._slot = "adopted"
            result, self._result = self._result, None
        self._settle(on_loop=True)
        return result

    def depart(self) -> None:
        """The waiter gave up: close a pending gate, or move a delivered result to off-loop cleanup."""
        if self.close_and_settle(on_loop=True):
            return
        with self._lock:
            self._departed = True
            if self._slot != "delivered":
                return
            self._slot = "cleanupPending"
            result, self._result = self._result, None
        self._offload(functools.partial(self._dispose_and_settle, result), True)

    def _dispose_and_settle(self, result: Any) -> None:
        try:
            if self._dispose is not None:
                self._dispose(result)
        except BaseException:
            with self._lock:
                self._slot = "retainedFailed"
            raise
        with self._lock:
            self._slot = "disposed"
        self._settle(on_loop=False)


async def run_owned_job(
    executor: Executor, job: Callable[[], Any], *, offload: Offload, timeout: float | None,
    dispose: Callable[[Any], None] | None = None, retain: Callable[[Any, BaseException], None] | None = None,
    on_return: Callable[[], None] | None = None,
) -> Any:
    """Runs `job` on `executor`; its result, if any, has one owner at every instant (see `_OwnedHandoff`).

    Returns the adopted result. A deadline raises `BlobDeadline` and a cancellation re-raises, after the waiter
    departs. A submit error is raised only once the gate proves non-entry; if the job already entered, its real
    result is awaited instead, and a proven non-entry raises `BlobCancelled` chained to the submit error. A job
    that never enters (executor cancellation, initializer failure) raises `BlobCancelled` or that exception, after
    `on_return`. A job's own `TimeoutError` is re-raised, not mistaken for the deadline.
    """
    loop = asyncio.get_running_loop()
    handoff = _OwnedHandoff(job, dispose, retain, on_return, loop, offload)
    del job, on_return
    submitted: Future[Any] | None
    try:
        submitted = executor.submit(handoff.run)
    except BaseException as error:
        if handoff.close_and_settle(on_loop=True):
            raise BlobCancelled("blob job was not accepted") from error
        submitted = None
    if submitted is not None:
        submitted.add_done_callback(handoff.finished)
    try:
        await asyncio.wait_for(asyncio.shield(handoff.done), timeout)
    except TimeoutError:
        if handoff.done.done() and not handoff.done.cancelled():
            raise
        handoff.depart()
        raise BlobDeadline() from None
    except asyncio.CancelledError:
        handoff.depart()
        raise
    return handoff.adopt()


def _full(error: sqlite3.Error) -> bool:
    return (getattr(error, "sqlite_errorcode", 0) & 0xFF) == sqlite3.SQLITE_FULL


def _supported_sqlite_build() -> bool:
    """Refuses SQLite builds that force temporary files to disk. Returns whether temporary storage is always memory."""
    db = sqlite3.connect(":memory:")
    try:
        options = {row[0] for row in db.execute("PRAGMA compile_options")}
    finally:
        db.close()
    if not options & SUPPORTED_TEMP_STORE:
        raise BlobStoreUnsupported("SQLite build does not allow in-memory temporary storage")
    return "TEMP_STORE=3" in options


def _owned_bytes(file: str, status: tuple[str, int] | None) -> int:
    if status is None or status[0] == "link":
        return 0
    if status[0] == "other":
        raise BlobStoreCorrupt(f"unexpected entry at blob part path {file}")
    return status[1]


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
        if type(size) is not int or size < 0:
            raise corrupt("doomed size")
    for route, object_, _wanted_at in db.execute("SELECT * FROM blob_wanted"):
        if type(route) is not bytes or len(route) != ID_BYTES or type(object_) is not bytes or len(object_) != ID_BYTES:
            raise corrupt("wanted row")
    stored = {row[0]: list(row[1:]) for row in db.execute("SELECT * FROM blob_usage")}
    if stored != usage:
        raise corrupt("usage counters")
