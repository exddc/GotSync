from __future__ import annotations

import base64
import hashlib
import hmac
import math
import os
import sqlite3
import stat
import threading
import time
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from pathlib import Path

MAILBOX_ROUTE_CONTEXT = b"com.gotdone.sync/mailbox-route/v1"
PAIRING_CONTROL_ROUTE_CONTEXT = b"com.gotdone.sync/pairing-control-route/v2"
MAX_MAILBOX_PAYLOAD_BYTES = 64 * 1024
MAX_MAILBOX_BATCH_MESSAGES = 128
MAX_MAILBOX_REQUEST_BYTES = 512 * 1024
MAX_MAILBOX_RESPONSE_BYTES = 512 * 1024
DEFAULT_MAILBOX_RETENTION_SECONDS = 365 * 24 * 60 * 60
DEFAULT_MAILBOX_PURGE_INTERVAL_SECONDS = 60 * 60
DEFAULT_MAX_ROUTE_RECEIPTS = 10_000
DEFAULT_MAX_ROUTE_LIVE_BYTES = 64 * 1024 * 1024
DEFAULT_MAX_GLOBAL_RECEIPTS = 1_000_000
DEFAULT_MAX_GLOBAL_LIVE_BYTES = 1024 * 1024 * 1024


class MailboxError(ValueError):
    code = "invalidRequest"
    status = 400


class MailboxAuthorizationError(MailboxError):
    code = "unauthorized"
    status = 401


class MailboxConflictError(MailboxError):
    code = "messageConflict"
    status = 409


class MailboxCapacityError(MailboxError):
    code = "mailboxCapacity"
    status = 429


class MailboxRequestTooLargeError(MailboxError):
    code = "requestTooLarge"
    status = 413


class MailboxHeadersTooLargeError(MailboxError):
    code = "headersTooLarge"
    status = 431


@dataclass(frozen=True, slots=True)
class MailboxPutMessage:
    message_id: bytes
    payload: bytes


@dataclass(frozen=True, slots=True)
class MailboxStoredMessage:
    message_id: bytes
    cursor: int
    acknowledged: bool


@dataclass(frozen=True, slots=True)
class MailboxFetchedMessage:
    message_id: bytes
    cursor: int
    payload: bytes


@dataclass(frozen=True, slots=True)
class MailboxFetchPage:
    messages: tuple[MailboxFetchedMessage, ...]
    next_cursor: int
    has_more: bool


def encode_base64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def decode_canonical_base64url(
    value: object,
    *,
    field: str,
    exact_bytes: int | None = None,
    maximum_bytes: int | None = None,
) -> bytes:
    if not isinstance(value, str):
        raise MailboxError(f"{field} must be a base64url string")
    try:
        encoded = value.encode("ascii")
    except UnicodeEncodeError as error:
        raise MailboxError(f"{field} is not canonical base64url") from error
    if b"=" in encoded:
        raise MailboxError(f"{field} is not canonical base64url")
    padding = b"=" * ((4 - len(encoded) % 4) % 4)
    try:
        decoded = base64.b64decode(
            encoded + padding,
            altchars=b"-_",
            validate=True,
        )
    except ValueError as error:
        raise MailboxError(f"{field} is not canonical base64url") from error
    if base64.urlsafe_b64encode(decoded).rstrip(b"=") != encoded:
        raise MailboxError(f"{field} is not canonical base64url")
    if exact_bytes is not None and len(decoded) != exact_bytes:
        raise MailboxError(f"{field} has the wrong length")
    if maximum_bytes is not None and len(decoded) > maximum_bytes:
        raise MailboxError(f"{field} is too large")
    return decoded


def mailbox_route_for_auth(auth: bytes) -> bytes:
    if len(auth) != 32:
        raise MailboxError("auth has the wrong length")
    return hashlib.sha256(MAILBOX_ROUTE_CONTEXT + auth).digest()


def pairing_control_route_for_auth(auth: bytes) -> bytes:
    if len(auth) != 32:
        raise MailboxError("auth has the wrong length")
    return hashlib.sha256(PAIRING_CONTROL_ROUTE_CONTEXT + auth).digest()


def authorize_mailbox(route: bytes, auth: bytes) -> None:
    if len(route) != 32 or len(auth) != 32:
        raise MailboxAuthorizationError("invalid mailbox authorization")
    mailbox_route_matches = hmac.compare_digest(
        route,
        mailbox_route_for_auth(auth),
    )
    pairing_control_route_matches = hmac.compare_digest(
        route,
        pairing_control_route_for_auth(auth),
    )
    if not (mailbox_route_matches | pairing_control_route_matches):
        raise MailboxAuthorizationError("invalid mailbox authorization")


class MailboxStore:
    def __init__(
        self,
        database_path: str | os.PathLike[str],
        *,
        retention_seconds: float = DEFAULT_MAILBOX_RETENTION_SECONDS,
        max_route_receipts: int = DEFAULT_MAX_ROUTE_RECEIPTS,
        max_route_live_bytes: int = DEFAULT_MAX_ROUTE_LIVE_BYTES,
        max_global_receipts: int = DEFAULT_MAX_GLOBAL_RECEIPTS,
        max_global_live_bytes: int = DEFAULT_MAX_GLOBAL_LIVE_BYTES,
        clock: Callable[[], float] = time.time,
    ) -> None:
        if not math.isfinite(retention_seconds) or retention_seconds <= 0:
            raise ValueError("retention_seconds must be finite and positive")
        limits = (
            max_route_receipts,
            max_route_live_bytes,
            max_global_receipts,
            max_global_live_bytes,
        )
        if any(limit <= 0 for limit in limits):
            raise ValueError("mailbox capacity limits must be positive")

        self.database_path = Path(database_path)
        self.retention_seconds = retention_seconds
        self.max_route_receipts = max_route_receipts
        self.max_route_live_bytes = max_route_live_bytes
        self.max_global_receipts = max_global_receipts
        self.max_global_live_bytes = max_global_live_bytes
        self._clock = clock
        self._lock = threading.RLock()
        self._closed = False

        if not self.database_path.parent.exists():
            self.database_path.parent.mkdir(mode=0o700, parents=True)
        try:
            descriptor = os.open(
                self.database_path,
                os.O_CREAT | os.O_EXCL | os.O_RDWR,
                0o600,
            )
        except FileExistsError:
            if not stat.S_ISREG(os.lstat(self.database_path).st_mode):
                raise ValueError("mailbox database path must be a regular file")
            self.database_path.chmod(0o600)
        else:
            os.close(descriptor)

        self._connection = sqlite3.connect(
            self.database_path,
            isolation_level=None,
            check_same_thread=False,
            timeout=5,
        )
        self._connection.execute("PRAGMA busy_timeout = 5000")
        self._connection.execute("PRAGMA trusted_schema = OFF")
        self._connection.execute("PRAGMA temp_store = MEMORY")
        self._connection.execute("PRAGMA secure_delete = ON")
        self._connection.execute("PRAGMA journal_mode = WAL")
        self._connection.execute("PRAGMA synchronous = FULL")
        self._connection.executescript(
            """
            CREATE TABLE IF NOT EXISTS mailbox_messages (
                cursor INTEGER PRIMARY KEY AUTOINCREMENT,
                route BLOB NOT NULL,
                message_id BLOB NOT NULL,
                payload BLOB,
                payload_hash BLOB NOT NULL,
                expires_at REAL NOT NULL,
                UNIQUE(route, message_id)
            );
            CREATE INDEX IF NOT EXISTS mailbox_route_cursor
                ON mailbox_messages(route, cursor);
            CREATE INDEX IF NOT EXISTS mailbox_expiry
                ON mailbox_messages(expires_at);
            CREATE TABLE IF NOT EXISTS mailbox_readiness (
                singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                generation INTEGER NOT NULL
            );
            INSERT OR IGNORE INTO mailbox_readiness(singleton, generation)
            VALUES (1, 0);
            """
        )
        columns = {
            str(row[1])
            for row in self._connection.execute(
                "PRAGMA table_info(mailbox_messages)"
            )
        }
        if "created_at" in columns:
            self._connection.execute(
                "ALTER TABLE mailbox_messages DROP COLUMN created_at"
            )
        self._harden_file_permissions()

    def close(self) -> None:
        with self._lock:
            if self._closed:
                return
            self._connection.close()
            self._closed = True

    def __enter__(self) -> MailboxStore:
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def put(
        self,
        route: bytes,
        messages: Sequence[MailboxPutMessage],
    ) -> tuple[MailboxStoredMessage, ...]:
        if len(route) != 32:
            raise MailboxError("route has the wrong length")
        if not 1 <= len(messages) <= MAX_MAILBOX_BATCH_MESSAGES:
            raise MailboxError("messages batch has the wrong size")

        seen_ids: set[bytes] = set()
        for message in messages:
            if len(message.message_id) != 32:
                raise MailboxError("message id has the wrong length")
            if len(message.payload) > MAX_MAILBOX_PAYLOAD_BYTES:
                raise MailboxError("message payload is too large")
            if message.message_id in seen_ids:
                raise MailboxError("messages contains duplicate ids")
            seen_ids.add(message.message_id)

        now = self._now()
        expires_at = now + self.retention_seconds
        with self._transaction():
            self._purge_expired(now)
            existing_rows: dict[bytes, tuple[int, bytes, bool]] = {}
            placeholders = ",".join("?" for _ in messages)
            rows = self._connection.execute(
                f"""
                SELECT message_id, cursor, payload_hash, payload IS NULL
                FROM mailbox_messages
                WHERE route = ? AND message_id IN ({placeholders})
                """,
                (route, *(message.message_id for message in messages)),
            )
            for message_id, cursor, payload_hash, acknowledged in rows:
                existing_rows[bytes(message_id)] = (
                    int(cursor),
                    bytes(payload_hash),
                    bool(acknowledged),
                )

            new_messages: list[tuple[MailboxPutMessage, bytes]] = []
            for message in messages:
                payload_hash = hashlib.sha256(message.payload).digest()
                existing = existing_rows.get(message.message_id)
                if existing is None:
                    new_messages.append((message, payload_hash))
                elif not hmac.compare_digest(existing[1], payload_hash):
                    raise MailboxConflictError(
                        "message id was previously used for different bytes"
                    )

            if new_messages:
                self._check_capacity(
                    route,
                    additional_receipts=len(new_messages),
                    additional_live_bytes=sum(
                        len(message.payload) for message, _ in new_messages
                    ),
                )
                existing_expiry = self._connection.execute(
                    """
                    SELECT MIN(expires_at)
                    FROM mailbox_messages
                    WHERE route = ? AND payload IS NOT NULL
                    """,
                    (route,),
                ).fetchone()[0]
                route_expires_at = (
                    float(existing_expiry)
                    if existing_expiry is not None
                    else expires_at
                )
                for message, payload_hash in new_messages:
                    cursor = self._connection.execute(
                        """
                        INSERT INTO mailbox_messages(
                            route,
                            message_id,
                            payload,
                            payload_hash,
                            expires_at
                        ) VALUES (?, ?, ?, ?, ?)
                        """,
                        (
                            route,
                            message.message_id,
                            message.payload,
                            payload_hash,
                            route_expires_at,
                        ),
                    ).lastrowid
                    if cursor is None:
                        raise RuntimeError("SQLite did not assign a mailbox cursor")
                    existing_rows[message.message_id] = (
                        int(cursor),
                        payload_hash,
                        False,
                    )

            return tuple(
                MailboxStoredMessage(
                    message_id=message.message_id,
                    cursor=existing_rows[message.message_id][0],
                    acknowledged=existing_rows[message.message_id][2],
                )
                for message in messages
            )

    def fetch(
        self,
        route: bytes,
        *,
        after_cursor: int,
        limit: int = MAX_MAILBOX_BATCH_MESSAGES,
    ) -> MailboxFetchPage:
        if len(route) != 32:
            raise MailboxError("route has the wrong length")
        if not 0 <= after_cursor <= 2**63 - 1:
            raise MailboxError("after cursor is out of range")
        if not 1 <= limit <= MAX_MAILBOX_BATCH_MESSAGES:
            raise MailboxError("limit is out of range")

        now = self._now()
        with self._transaction():
            self._purge_expired(now)
            rows = self._connection.execute(
                """
                SELECT cursor, message_id, payload
                FROM mailbox_messages
                WHERE route = ? AND cursor > ? AND payload IS NOT NULL
                ORDER BY cursor
                LIMIT ?
                """,
                (route, after_cursor, limit + 1),
            ).fetchall()

        has_more = len(rows) > limit
        visible_rows = rows[:limit]
        messages = tuple(
            MailboxFetchedMessage(
                message_id=bytes(message_id),
                cursor=int(cursor),
                payload=bytes(payload),
            )
            for cursor, message_id, payload in visible_rows
        )
        next_cursor = messages[-1].cursor if messages else after_cursor
        return MailboxFetchPage(
            messages=messages,
            next_cursor=next_cursor,
            has_more=has_more,
        )

    def acknowledge(self, route: bytes, *, through_cursor: int) -> int:
        if len(route) != 32:
            raise MailboxError("route has the wrong length")
        if not 0 <= through_cursor <= 2**63 - 1:
            raise MailboxError("cursor is out of range")

        now = self._now()
        with self._transaction():
            self._purge_expired(now)
            result = self._connection.execute(
                """
                UPDATE mailbox_messages
                SET payload = NULL
                WHERE route = ? AND cursor <= ? AND payload IS NOT NULL
                """,
                (route, through_cursor),
            )
            return int(result.rowcount)

    def forget(self, route: bytes) -> int:
        if len(route) != 32:
            raise MailboxError("route has the wrong length")

        with self._transaction():
            result = self._connection.execute(
                "DELETE FROM mailbox_messages WHERE route = ?",
                (route,),
            )
            return int(result.rowcount)

    def purge_expired(self) -> int:
        now = self._now()
        with self._transaction():
            return self._purge_expired(now)

    def counts(self) -> dict[str, int]:
        now = self._now()
        with self._transaction():
            self._purge_expired(now)
            receipts, live_messages, live_bytes = self._connection.execute(
                """
                SELECT
                    COUNT(*),
                    COUNT(payload),
                    COALESCE(SUM(LENGTH(payload)), 0)
                FROM mailbox_messages
                """
            ).fetchone()
            return {
                "receipts": int(receipts),
                "live_messages": int(live_messages),
                "live_bytes": int(live_bytes),
            }

    def is_ready(self, *, max_wait_seconds: float = 0.25) -> bool:
        if not math.isfinite(max_wait_seconds) or max_wait_seconds <= 0:
            raise ValueError("max_wait_seconds must be finite and positive")
        deadline = time.monotonic() + max_wait_seconds
        if not self._lock.acquire(timeout=max_wait_seconds):
            return False
        original_busy_timeout: int | None = None
        transaction_open = False
        try:
            if self._closed:
                return False
            try:
                original_busy_timeout = int(
                    self._connection.execute(
                        "PRAGMA busy_timeout"
                    ).fetchone()[0]
                )
                remaining_seconds = deadline - time.monotonic()
                if remaining_seconds <= 0:
                    return False
                readiness_timeout = max(
                    1,
                    math.ceil(remaining_seconds * 1_000),
                )
                self._connection.execute(
                    f"PRAGMA busy_timeout = {readiness_timeout}"
                )
                self._connection.execute("BEGIN IMMEDIATE")
                transaction_open = True

                page_count = int(
                    self._connection.execute(
                        "PRAGMA page_count"
                    ).fetchone()[0]
                )
                free_page_count = int(
                    self._connection.execute(
                        "PRAGMA freelist_count"
                    ).fetchone()[0]
                )
                max_page_count = int(
                    self._connection.execute(
                        "PRAGMA max_page_count"
                    ).fetchone()[0]
                )
                if page_count >= max_page_count and free_page_count == 0:
                    self._connection.execute("ROLLBACK")
                    transaction_open = False
                    return False

                result = self._connection.execute(
                    """
                    REPLACE INTO mailbox_readiness(singleton, generation)
                    SELECT singleton, generation
                    FROM mailbox_readiness
                    WHERE singleton = 1
                    """
                )
                if result.rowcount != 1:
                    self._connection.execute("ROLLBACK")
                    transaction_open = False
                    return False
                self._connection.execute("COMMIT")
                transaction_open = False
            except sqlite3.Error:
                if transaction_open:
                    try:
                        self._connection.execute("ROLLBACK")
                    except sqlite3.Error:
                        pass
                return False
            return True
        finally:
            if original_busy_timeout is not None and not self._closed:
                try:
                    self._connection.execute(
                        f"PRAGMA busy_timeout = {original_busy_timeout}"
                    )
                except sqlite3.Error:
                    pass
            self._lock.release()

    def _check_capacity(
        self,
        route: bytes,
        *,
        additional_receipts: int,
        additional_live_bytes: int,
    ) -> None:
        route_receipts, route_live_bytes = self._connection.execute(
            """
            SELECT COUNT(*), COALESCE(SUM(LENGTH(payload)), 0)
            FROM mailbox_messages
            WHERE route = ?
            """,
            (route,),
        ).fetchone()
        global_receipts, global_live_bytes = self._connection.execute(
            """
            SELECT COUNT(*), COALESCE(SUM(LENGTH(payload)), 0)
            FROM mailbox_messages
            """
        ).fetchone()
        if int(route_receipts) + additional_receipts > self.max_route_receipts:
            raise MailboxCapacityError("route receipt capacity reached")
        if int(route_live_bytes) + additional_live_bytes > self.max_route_live_bytes:
            raise MailboxCapacityError("route live-byte capacity reached")
        if int(global_receipts) + additional_receipts > self.max_global_receipts:
            raise MailboxCapacityError("global receipt capacity reached")
        if int(global_live_bytes) + additional_live_bytes > self.max_global_live_bytes:
            raise MailboxCapacityError("global live-byte capacity reached")

    def _now(self) -> float:
        now = float(self._clock())
        if not math.isfinite(now):
            raise RuntimeError("mailbox clock returned a non-finite value")
        return now

    def _purge_expired(self, now: float) -> int:
        result = self._connection.execute(
            "DELETE FROM mailbox_messages WHERE expires_at <= ?",
            (now,),
        )
        return int(result.rowcount)

    def _harden_file_permissions(self) -> None:
        try:
            self.database_path.chmod(0o600)
        except OSError:
            pass
        for suffix in ("-wal", "-shm"):
            companion = Path(f"{self.database_path}{suffix}")
            if companion.exists():
                try:
                    companion.chmod(0o600)
                except OSError:
                    pass

    class _Transaction:
        def __init__(self, store: MailboxStore) -> None:
            self.store = store

        def __enter__(self) -> None:
            self.store._lock.acquire()
            if self.store._closed:
                self.store._lock.release()
                raise RuntimeError("mailbox store is closed")
            try:
                self.store._connection.execute("BEGIN IMMEDIATE")
            except BaseException:
                self.store._lock.release()
                raise

        def __exit__(
            self,
            exception_type: type[BaseException] | None,
            _exception: BaseException | None,
            _traceback: object,
        ) -> None:
            try:
                if exception_type is None:
                    try:
                        self.store._connection.execute("COMMIT")
                    except BaseException:
                        try:
                            self.store._connection.execute("ROLLBACK")
                        except sqlite3.Error:
                            pass
                        raise
                else:
                    self.store._connection.execute("ROLLBACK")
            finally:
                self.store._harden_file_permissions()
                self.store._lock.release()

    def _transaction(self) -> MailboxStore._Transaction:
        return self._Transaction(self)
