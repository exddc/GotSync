from __future__ import annotations

import asyncio
import hashlib
import json
import os
import sqlite3
import tempfile
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
from pathlib import Path
from typing import Any

from gotsync_server.mailbox import (
    MAX_MAILBOX_BATCH_MESSAGES,
    MAX_MAILBOX_PAYLOAD_BYTES,
    MAX_MAILBOX_REQUEST_BYTES,
    MAX_MAILBOX_RESPONSE_BYTES,
    MailboxAuthorizationError,
    MailboxCapacityError,
    MailboxConflictError,
    MailboxError,
    MailboxPutMessage,
    MailboxStore,
    authorize_mailbox,
    encode_base64url,
    mailbox_route_for_auth,
    pairing_control_route_for_auth,
)
from gotsync_server.server import RelayServer


def key(seed: int) -> bytes:
    return bytes((seed + offset) % 256 for offset in range(32))


def put_message(seed: int, payload: bytes) -> MailboxPutMessage:
    return MailboxPutMessage(key(seed), payload)


class FakeClock:
    def __init__(self, value: float = 1_000.0) -> None:
        self.value = value

    def __call__(self) -> float:
        return self.value


class MailboxAuthorizationTests(unittest.TestCase):
    def test_accepts_both_fixed_route_namespaces(self) -> None:
        auth = key(1)

        authorize_mailbox(mailbox_route_for_auth(auth), auth)
        authorize_mailbox(pairing_control_route_for_auth(auth), auth)

    def test_rejects_unknown_and_mismatched_routes(self) -> None:
        auth = key(2)
        other_auth = key(3)
        rejected_routes = (
            hashlib.sha256(
                b"com.gotdone.sync/unknown-route/v1" + auth
            ).digest(),
            mailbox_route_for_auth(other_auth),
            pairing_control_route_for_auth(other_auth),
        )

        for route in rejected_routes:
            with self.subTest(route=encode_base64url(route)):
                with self.assertRaises(MailboxAuthorizationError):
                    authorize_mailbox(route, auth)


class MailboxStoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.database_path = Path(self.temporary_directory.name) / "mailbox.sqlite3"

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def store(self, **options: Any) -> MailboxStore:
        return MailboxStore(self.database_path, **options)

    def test_persists_messages_and_global_cursor_across_restart(self) -> None:
        route_a = mailbox_route_for_auth(key(1))
        route_b = mailbox_route_for_auth(key(2))
        with self.store() as store:
            first = store.put(route_a, [put_message(10, b"one")])[0]
            second = store.put(route_b, [put_message(11, b"two")])[0]
            self.assertLess(first.cursor, second.cursor)

        with self.store() as store:
            page_a = store.fetch(route_a, after_cursor=0)
            page_b = store.fetch(route_b, after_cursor=0)
            self.assertEqual(page_a.messages[0].payload, b"one")
            self.assertEqual(page_b.messages[0].payload, b"two")
            third = store.put(route_a, [put_message(12, b"three")])[0]
            self.assertGreater(third.cursor, second.cursor)

        self.assertEqual(self.database_path.stat().st_mode & 0o777, 0o600)

    def test_does_not_change_permissions_of_existing_database_parent(self) -> None:
        parent = Path(self.temporary_directory.name) / "shared"
        parent.mkdir(mode=0o755)
        parent.chmod(0o755)
        database_path = parent / "mailbox.sqlite3"

        with MailboxStore(database_path) as store:
            self.assertEqual(
                store._connection.execute(
                    "PRAGMA secure_delete"
                ).fetchone()[0],
                1,
            )

        self.assertEqual(parent.stat().st_mode & 0o777, 0o755)
        self.assertEqual(database_path.stat().st_mode & 0o777, 0o600)

    def test_removes_legacy_created_at_metadata_without_losing_messages(self) -> None:
        route = mailbox_route_for_auth(key(24))
        message = put_message(24, b"opaque")
        payload_hash = hashlib.sha256(message.payload).digest()
        with closing(
            sqlite3.connect(self.database_path)
        ) as connection, connection:
            connection.executescript(
                """
                CREATE TABLE mailbox_messages (
                    cursor INTEGER PRIMARY KEY AUTOINCREMENT,
                    route BLOB NOT NULL,
                    message_id BLOB NOT NULL,
                    payload BLOB,
                    payload_hash BLOB NOT NULL,
                    created_at REAL NOT NULL,
                    expires_at REAL NOT NULL,
                    UNIQUE(route, message_id)
                );
                """
            )
            connection.execute(
                """
                INSERT INTO mailbox_messages(
                    cursor,
                    route,
                    message_id,
                    payload,
                    payload_hash,
                    created_at,
                    expires_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    7,
                    route,
                    message.message_id,
                    message.payload,
                    payload_hash,
                    1,
                    10_000,
                ),
            )

        with self.store(clock=lambda: 2) as store:
            columns = {
                row[1]
                for row in store._connection.execute(
                    "PRAGMA table_info(mailbox_messages)"
                )
            }
            self.assertNotIn("created_at", columns)
            fetched = store.fetch(route, after_cursor=0)
            self.assertEqual(fetched.messages[0].cursor, 7)
            self.assertEqual(fetched.messages[0].payload, b"opaque")
            inserted = store.put(route, [put_message(25, b"next")])[0]
            self.assertGreater(inserted.cursor, 7)

    def test_idempotency_conflict_and_retry_after_acknowledgement(self) -> None:
        route = mailbox_route_for_auth(key(3))
        message = put_message(20, b"ciphertext")
        with self.store() as store:
            first = store.put(route, [message])[0]
            retry = store.put(route, [message])[0]
            self.assertEqual(retry.cursor, first.cursor)
            self.assertFalse(first.acknowledged)
            self.assertFalse(retry.acknowledged)

            with self.assertRaises(MailboxConflictError):
                store.put(route, [put_message(20, b"different")])

            self.assertEqual(
                store.acknowledge(route, through_cursor=first.cursor),
                1,
            )

        with self.store() as store:
            post_ack_retry = store.put(route, [message])[0]
            self.assertEqual(post_ack_retry.cursor, first.cursor)
            self.assertTrue(post_ack_retry.acknowledged)
            self.assertEqual(store.fetch(route, after_cursor=0).messages, ())
            self.assertEqual(
                store.counts(),
                {"live_bytes": 0, "live_messages": 0, "receipts": 1},
            )

    def test_fetch_is_ordered_and_ack_is_route_scoped(self) -> None:
        route_a = mailbox_route_for_auth(key(4))
        route_b = mailbox_route_for_auth(key(5))
        with self.store() as store:
            stored_a = store.put(
                route_a,
                [
                    put_message(30, b"a"),
                    put_message(31, b"b"),
                    put_message(32, b"c"),
                ],
            )
            stored_b = store.put(route_b, [put_message(33, b"other")])

            first_page = store.fetch(route_a, after_cursor=0, limit=2)
            self.assertEqual(
                [message.payload for message in first_page.messages],
                [b"a", b"b"],
            )
            self.assertTrue(first_page.has_more)
            self.assertEqual(first_page.next_cursor, stored_a[1].cursor)
            self.assertEqual(
                store.fetch(route_a, after_cursor=0, limit=2),
                first_page,
            )

            self.assertEqual(
                store.acknowledge(
                    route_a,
                    through_cursor=first_page.next_cursor,
                ),
                2,
            )
            remaining = store.fetch(route_a, after_cursor=0)
            self.assertEqual(
                [message.payload for message in remaining.messages],
                [b"c"],
            )
            self.assertEqual(
                store.fetch(route_b, after_cursor=0).messages[0].cursor,
                stored_b[0].cursor,
            )

    def test_new_put_does_not_extend_pending_queue_deadline(self) -> None:
        clock = FakeClock()
        route = mailbox_route_for_auth(key(6))
        with self.store(retention_seconds=10, clock=clock) as store:
            first = store.put(route, [put_message(40, b"old")])[0]
            clock.value += 6
            second = store.put(route, [put_message(41, b"new")])[0]

            clock.value += 3
            fetched = store.fetch(route, after_cursor=0)
            self.assertEqual(
                [message.cursor for message in fetched.messages],
                [first.cursor, second.cursor],
            )

            clock.value += 1
            self.assertEqual(store.fetch(route, after_cursor=0).messages, ())
            self.assertEqual(store.counts()["receipts"], 0)

    def test_new_queue_gets_full_retention_after_previous_queue_is_acked(self) -> None:
        clock = FakeClock()
        route = mailbox_route_for_auth(key(25))
        with self.store(retention_seconds=10, clock=clock) as store:
            first = store.put(route, [put_message(44, b"first")])[0]
            store.acknowledge(route, through_cursor=first.cursor)
            clock.value += 6
            second = store.put(route, [put_message(45, b"second")])[0]

            clock.value += 5
            fetched = store.fetch(route, after_cursor=first.cursor)
            self.assertEqual(
                [message.cursor for message in fetched.messages],
                [second.cursor],
            )

    def test_backward_clock_does_not_shorten_existing_retention(self) -> None:
        clock = FakeClock()
        route = mailbox_route_for_auth(key(21))
        with self.store(retention_seconds=10, clock=clock) as store:
            store.put(route, [put_message(42, b"old")])
            clock.value -= 5
            store.put(route, [put_message(43, b"new")])

            clock.value = 1_006
            self.assertEqual(
                [message.payload for message in store.fetch(route, after_cursor=0).messages],
                [b"old", b"new"],
            )
            clock.value = 1_010
            self.assertEqual(store.fetch(route, after_cursor=0).messages, ())

    def test_rejects_non_finite_retention_and_clock_values(self) -> None:
        for retention in (float("nan"), float("inf"), float("-inf")):
            with self.subTest(retention=retention):
                with self.assertRaisesRegex(ValueError, "finite"):
                    self.store(retention_seconds=retention)

        route = mailbox_route_for_auth(key(22))
        with self.store(clock=lambda: float("nan")) as store:
            with self.assertRaisesRegex(RuntimeError, "clock"):
                store.fetch(route, after_cursor=0)

    def test_readiness_requires_a_writable_store(self) -> None:
        with self.store() as store:
            original_generation = store._connection.execute(
                """
                SELECT generation
                FROM mailbox_readiness
                WHERE singleton = 1
                """
            ).fetchone()[0]
            self.assertTrue(store.is_ready())
            self.assertEqual(
                store._connection.execute(
                    """
                    SELECT generation
                    FROM mailbox_readiness
                    WHERE singleton = 1
                    """
                ).fetchone()[0],
                original_generation,
            )
            store._connection.execute("PRAGMA query_only = ON")
            self.assertFalse(store.is_ready())
            store._connection.execute("PRAGMA query_only = OFF")
            self.assertTrue(store.is_ready())
            store.close()
            self.assertFalse(store.is_ready())

    def test_readiness_rejects_exhausted_database_page_capacity(self) -> None:
        with self.store() as store:
            store._connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            page_count = int(
                store._connection.execute(
                    "PRAGMA page_count"
                ).fetchone()[0]
            )
            configured_max = int(
                store._connection.execute(
                    f"PRAGMA max_page_count = {page_count}"
                ).fetchone()[0]
            )
            self.assertEqual(configured_max, page_count)
            self.assertEqual(
                store._connection.execute(
                    "PRAGMA freelist_count"
                ).fetchone()[0],
                0,
            )
            with self.assertRaisesRegex(
                sqlite3.OperationalError,
                "full",
            ):
                store._connection.execute(
                    """
                    INSERT INTO mailbox_messages(
                        route,
                        message_id,
                        payload,
                        payload_hash,
                        expires_at
                    ) VALUES (?, ?, zeroblob(65536), ?, ?)
                    """,
                    (
                        bytes(32),
                        bytes([1]) * 32,
                        bytes([2]) * 32,
                        2_000,
                    ),
                )
            self.assertFalse(store.is_ready())

    def test_readiness_is_bounded_while_another_writer_holds_database(
        self,
    ) -> None:
        with self.store() as store:
            with closing(
                sqlite3.connect(
                    self.database_path,
                    isolation_level=None,
                    timeout=0.1,
                )
            ) as blocker:
                blocker.execute("BEGIN IMMEDIATE")
                blocker.execute(
                    """
                    UPDATE mailbox_readiness
                    SET generation = generation + 1
                    WHERE singleton = 1
                    """
                )
                started = time.monotonic()
                self.assertFalse(
                    store.is_ready(max_wait_seconds=0.05)
                )
                elapsed = time.monotonic() - started
                self.assertLess(elapsed, 0.5)
                blocker.rollback()
            self.assertTrue(store.is_ready())

    def test_receipt_and_live_byte_caps_are_transactional(self) -> None:
        route = mailbox_route_for_auth(key(7))
        with self.store(
            max_route_receipts=2,
            max_route_live_bytes=4,
            max_global_receipts=2,
            max_global_live_bytes=4,
        ) as store:
            stored = store.put(
                route,
                [put_message(50, b"aa"), put_message(51, b"bb")],
            )
            with self.assertRaises(MailboxCapacityError):
                store.put(route, [put_message(52, b"c")])
            self.assertEqual(store.counts()["receipts"], 2)

            store.acknowledge(route, through_cursor=stored[-1].cursor)
            with self.assertRaises(MailboxCapacityError):
                store.put(route, [put_message(52, b"c")])
            self.assertEqual(store.forget(route), 2)
            self.assertEqual(store.forget(route), 0)
            store.put(route, [put_message(50, b"1234")])
            with self.assertRaises(MailboxCapacityError):
                store.put(route, [put_message(53, b"x")])

    def test_route_and_global_caps_are_enforced_independently(self) -> None:
        route_a = mailbox_route_for_auth(key(17))
        route_b = mailbox_route_for_auth(key(18))
        route_c = mailbox_route_for_auth(key(19))
        with self.store(
            max_route_receipts=1,
            max_route_live_bytes=16,
            max_global_receipts=2,
            max_global_live_bytes=32,
        ) as store:
            store.put(route_a, [put_message(54, b"a")])
            with self.assertRaises(MailboxCapacityError):
                store.put(route_a, [put_message(55, b"b")])
            store.put(route_b, [put_message(54, b"other route")])
            with self.assertRaises(MailboxCapacityError):
                store.put(route_c, [put_message(56, b"c")])

    def test_concurrent_writers_cannot_overshoot_capacity(self) -> None:
        route = mailbox_route_for_auth(key(20))
        first_store = self.store(
            max_route_receipts=1,
            max_route_live_bytes=16,
            max_global_receipts=1,
            max_global_live_bytes=16,
        )
        second_store = self.store(
            max_route_receipts=1,
            max_route_live_bytes=16,
            max_global_receipts=1,
            max_global_live_bytes=16,
        )
        try:
            def attempt(store: MailboxStore, seed: int) -> str:
                try:
                    store.put(route, [put_message(seed, b"x")])
                except MailboxCapacityError:
                    return "capacity"
                return "stored"

            with ThreadPoolExecutor(max_workers=2) as executor:
                futures = (
                    executor.submit(attempt, first_store, 57),
                    executor.submit(attempt, second_store, 58),
                )
                outcomes = sorted(future.result() for future in futures)
            self.assertEqual(outcomes, ["capacity", "stored"])
            self.assertEqual(first_store.counts()["receipts"], 1)
        finally:
            first_store.close()
            second_store.close()

    def test_rejects_payload_batch_and_duplicate_id_bounds(self) -> None:
        route = mailbox_route_for_auth(key(8))
        with self.store() as store:
            with self.assertRaises(MailboxError):
                store.put(
                    route,
                    [put_message(60, b"x" * (MAX_MAILBOX_PAYLOAD_BYTES + 1))],
                )
            with self.assertRaises(MailboxError):
                store.put(
                    route,
                    [
                        put_message(70 + index, b"x")
                        for index in range(MAX_MAILBOX_BATCH_MESSAGES + 1)
                    ],
                )
            with self.assertRaises(MailboxError):
                store.put(
                    route,
                    [put_message(61, b"a"), put_message(61, b"a")],
                )
            self.assertEqual(store.counts()["receipts"], 0)


class MailboxHTTPTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.database_path = Path(self.temporary_directory.name) / "mailbox.sqlite3"
        self.relay = RelayServer(
            port=0,
            metrics_port=0,
            mailbox_port=0,
            mailbox_database_path=self.database_path,
        )
        await self.relay.start()

    async def asyncTearDown(self) -> None:
        await self.relay.close()
        self.temporary_directory.cleanup()

    async def request_json(
        self,
        target: str,
        document: dict[str, Any],
    ) -> tuple[int, dict[str, Any], bytes]:
        body = json.dumps(
            document,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
        return await self.raw_request(
            (
                f"POST {target} HTTP/1.1\r\n"
                "Host: localhost\r\n"
                "Content-Type: application/json\r\n"
                f"Content-Length: {len(body)}\r\n"
                "Connection: close\r\n"
                "\r\n"
            ).encode("ascii")
            + body
        )

    async def test_mailbox_accepts_explicit_and_legacy_versions(self) -> None:
        auth = key(0x51)
        route = mailbox_route_for_auth(auth)
        credentials = {"route": encode_base64url(route), "auth": encode_base64url(auth)}
        for explicit in (False, True):
            base = dict(credentials)
            if explicit:
                base["version"] = 1
            status, stored, _ = await self.request_json("/v1/mailbox/put", {
                **base, "messages": [{"id": encode_base64url(key(0x61)), "payload": encode_base64url(b"encrypted-payload")}],
            })
            self.assertEqual(status, 200)
            self.assertEqual(stored["version"], 1)
            cursor = stored["messages"][0]["cursor"]
            status, page, _ = await self.request_json("/v1/mailbox/fetch", {**base, "after": 0, "limit": 1})
            self.assertEqual(status, 200)
            self.assertEqual(len(page["messages"]), 1)
            status, acked, _ = await self.request_json("/v1/mailbox/ack", {**base, "cursor": cursor})
            self.assertEqual(status, 200)
            self.assertEqual(acked["version"], 1)
            status, forgotten, _ = await self.request_json("/v1/mailbox/forget", base)
            self.assertEqual(status, 200)
            self.assertTrue(forgotten["forgotten"])

    async def test_mailbox_rejects_unsupported_versions_before_mutation(self) -> None:
        auth = key(0x71)
        route = mailbox_route_for_auth(auth)
        credentials = {"route": encode_base64url(route), "auth": encode_base64url(auth)}
        operations = {
            "put": {"messages": [{"id": encode_base64url(key(0x72)), "payload": encode_base64url(b"encrypted-payload")}]},
            "fetch": {"after": 0},
            "ack": {"cursor": 1},
            "forget": {},
        }
        for version in (0, 2, -1, True, False, 1.0, "1", None):
            for operation, fields in operations.items():
                with self.subTest(version=version, operation=operation):
                    status, response, _ = await self.request_json(f"/v1/mailbox/{operation}", {
                        **credentials, **fields, "version": version,
                    })
                    self.assertEqual(status, 400)
                    self.assertEqual(response, {"error": "unsupportedVersion", "version": 1})
        page = self.relay.mailbox.fetch(route, after_cursor=0, limit=1)
        self.assertEqual(page.messages, ())

    async def raw_request(
        self,
        request: bytes,
        *,
        metrics: bool = False,
    ) -> tuple[int, dict[str, Any], bytes]:
        port = (
            self.relay.bound_metrics_port
            if metrics
            else self.relay.bound_mailbox_port
        )
        reader, writer = await asyncio.open_connection("127.0.0.1", port)
        writer.write(request)
        await writer.drain()
        response = await asyncio.wait_for(reader.read(), 2)
        writer.close()
        await writer.wait_closed()
        head, body = response.split(b"\r\n\r\n", 1)
        status = int(head.split(b" ", 2)[1])
        return status, json.loads(body), response

    @staticmethod
    def credentials(seed: int) -> tuple[bytes, dict[str, str]]:
        auth = key(seed)
        route = mailbox_route_for_auth(auth)
        return route, {
            "auth": encode_base64url(auth),
            "route": encode_base64url(route),
        }

    async def test_http_authorization_accepts_only_fixed_route_namespaces(
        self,
    ) -> None:
        auth = key(27)
        allowed_routes = (
            mailbox_route_for_auth(auth),
            pairing_control_route_for_auth(auth),
        )
        for route in allowed_routes:
            with self.subTest(route=encode_base64url(route)):
                status, _, _ = await self.request_json(
                    "/v1/mailbox/fetch",
                    {
                        "auth": encode_base64url(auth),
                        "route": encode_base64url(route),
                        "after": 0,
                    },
                )
                self.assertEqual(status, 200)

        rejected_credentials = (
            {
                "auth": encode_base64url(auth),
                "route": encode_base64url(
                    hashlib.sha256(
                        b"com.gotdone.sync/unknown-route/v1" + auth
                    ).digest()
                ),
            },
            {
                "auth": encode_base64url(key(28)),
                "route": encode_base64url(mailbox_route_for_auth(auth)),
            },
            {
                "auth": encode_base64url(key(28)),
                "route": encode_base64url(pairing_control_route_for_auth(auth)),
            },
        )
        for credentials in rejected_credentials:
            with self.subTest(route=credentials["route"]):
                status, response, _ = await self.request_json(
                    "/v1/mailbox/fetch",
                    {**credentials, "after": 0},
                )
                self.assertEqual(status, 401)
                self.assertEqual(response["error"], "unauthorized")

    async def test_authorization_and_route_isolation(self) -> None:
        route_a, credentials_a = self.credentials(10)
        _, credentials_b = self.credentials(11)
        message_id = key(80)
        put_status, _, _ = await self.request_json(
            "/v1/mailbox/put",
            {
                **credentials_a,
                "messages": [
                    {
                        "id": encode_base64url(message_id),
                        "payload": encode_base64url(b"opaque"),
                    }
                ],
            },
        )
        self.assertEqual(put_status, 200)

        second_put_status, _, _ = await self.request_json(
            "/v1/mailbox/put",
            {
                **credentials_b,
                "messages": [
                    {
                        "id": encode_base64url(message_id),
                        "payload": encode_base64url(b"different-route-bytes"),
                    }
                ],
            },
        )
        self.assertEqual(second_put_status, 200)

        fetch_status, fetched_b, _ = await self.request_json(
            "/v1/mailbox/fetch", {**credentials_b, "after": 0}
        )
        self.assertEqual(fetch_status, 200)
        self.assertEqual(
            fetched_b["messages"][0]["payload"],
            encode_base64url(b"different-route-bytes"),
        )

        wrong_auth = {
            "auth": credentials_b["auth"],
            "route": encode_base64url(route_a),
        }
        unauthorized_status, unauthorized, _ = await self.request_json(
            "/v1/mailbox/fetch",
            {**wrong_auth, "after": 0},
        )
        self.assertEqual(unauthorized_status, 401)
        self.assertEqual(unauthorized["error"], "unauthorized")

    async def test_put_fetch_ack_and_post_ack_retry_over_http(self) -> None:
        _, credentials = self.credentials(12)
        message_id = encode_base64url(key(90))
        put_document = {
            **credentials,
            "messages": [
                {"id": message_id, "payload": encode_base64url(b"ciphertext")}
            ],
        }
        first_status, first, _ = await self.request_json(
            "/v1/mailbox/put",
            put_document,
        )
        retry_status, retry, _ = await self.request_json(
            "/v1/mailbox/put",
            put_document,
        )
        self.assertEqual((first_status, retry_status), (200, 200))
        self.assertEqual(first, retry)
        self.assertFalse(first["messages"][0]["acknowledged"])
        cursor = first["messages"][0]["cursor"]

        fetch_status, fetched, _ = await self.request_json(
            "/v1/mailbox/fetch",
            {**credentials, "after": 0, "limit": 1},
        )
        self.assertEqual(fetch_status, 200)
        self.assertEqual(
            fetched["messages"][0]["payload"],
            encode_base64url(b"ciphertext"),
        )

        ack_status, acked, _ = await self.request_json(
            "/v1/mailbox/ack",
            {**credentials, "cursor": cursor},
        )
        self.assertEqual(ack_status, 200)
        self.assertEqual(acked["acked"], 1)

        retry_status, retry, _ = await self.request_json(
            "/v1/mailbox/put",
            put_document,
        )
        self.assertEqual(retry_status, 200)
        self.assertEqual(retry["messages"][0]["cursor"], cursor)
        self.assertTrue(retry["messages"][0]["acknowledged"])
        _, empty, _ = await self.request_json(
            "/v1/mailbox/fetch",
            {**credentials, "after": 0},
        )
        self.assertEqual(empty["messages"], [])

        conflict_document = {
            **credentials,
            "messages": [
                {"id": message_id, "payload": encode_base64url(b"different")}
            ],
        }
        conflict_status, conflict, _ = await self.request_json(
            "/v1/mailbox/put",
            conflict_document,
        )
        self.assertEqual(conflict_status, 409)
        self.assertEqual(conflict["error"], "messageConflict")

    async def test_forget_is_idempotent_authorized_and_isolated(self) -> None:
        _, credentials_a = self.credentials(13)
        _, credentials_b = self.credentials(14)
        for credentials, seed in ((credentials_a, 100), (credentials_b, 101)):
            status, _, _ = await self.request_json(
                "/v1/mailbox/put",
                {
                    **credentials,
                    "messages": [
                        {
                            "id": encode_base64url(key(seed)),
                            "payload": encode_base64url(b"opaque"),
                        }
                    ],
                },
            )
            self.assertEqual(status, 200)

        for _ in range(2):
            status, response, _ = await self.request_json(
                "/v1/mailbox/forget",
                credentials_a,
            )
            self.assertEqual(status, 200)
            self.assertTrue(response["forgotten"])

        _, fetched_a, _ = await self.request_json(
            "/v1/mailbox/fetch",
            {**credentials_a, "after": 0},
        )
        _, fetched_b, _ = await self.request_json(
            "/v1/mailbox/fetch",
            {**credentials_b, "after": 0},
        )
        self.assertEqual(fetched_a["messages"], [])
        self.assertEqual(len(fetched_b["messages"]), 1)

        wrong_auth = {
            "auth": credentials_b["auth"],
            "route": credentials_a["route"],
        }
        status, _, _ = await self.request_json(
            "/v1/mailbox/forget",
            wrong_auth,
        )
        self.assertEqual(status, 401)

    async def test_fetch_pages_are_bounded_by_serialized_response_bytes(self) -> None:
        route, credentials = self.credentials(17)
        messages = [
            put_message(120 + index, b"x" * MAX_MAILBOX_PAYLOAD_BYTES)
            for index in range(8)
        ]
        put_status, _, _ = await self.request_json(
            "/v1/mailbox/put",
            {
                **credentials,
                "messages": [
                    {
                        "id": encode_base64url(message.message_id),
                        "payload": encode_base64url(message.payload),
                    }
                    for message in messages[:5]
                ],
            },
        )
        self.assertEqual(put_status, 200)
        await asyncio.to_thread(self.relay.mailbox.put, route, messages[5:])

        status, first_page, raw_response = await self.request_json(
            "/v1/mailbox/fetch",
            {**credentials, "after": 0},
        )
        self.assertEqual(status, 200)
        response_body = raw_response.split(b"\r\n\r\n", 1)[1]
        self.assertLessEqual(len(response_body), MAX_MAILBOX_RESPONSE_BYTES)
        self.assertTrue(first_page["hasMore"])
        self.assertGreater(len(first_page["messages"]), 0)
        self.assertLess(len(first_page["messages"]), len(messages))

        status, second_page, raw_response = await self.request_json(
            "/v1/mailbox/fetch",
            {**credentials, "after": first_page["nextCursor"]},
        )
        self.assertEqual(status, 200)
        response_body = raw_response.split(b"\r\n\r\n", 1)[1]
        self.assertLessEqual(len(response_body), MAX_MAILBOX_RESPONSE_BYTES)
        self.assertFalse(second_page["hasMore"])
        returned_ids = {
            message["id"]
            for message in first_page["messages"] + second_page["messages"]
        }
        self.assertEqual(
            returned_ids,
            {encode_base64url(message.message_id) for message in messages},
        )

    async def test_rejects_malformed_duplicate_and_oversized_requests(self) -> None:
        _, credentials = self.credentials(15)
        duplicate_body = (
            "{"
            f'"route":"{credentials["route"]}",'
            f'"auth":"{credentials["auth"]}",'
            '"after":0,"after":1'
            "}"
        ).encode("utf-8")
        duplicate_status, _, _ = await self.raw_request(
            (
                b"POST /v1/mailbox/fetch HTTP/1.1\r\n"
                b"Host: localhost\r\n"
                b"Content-Type: application/json\r\n"
                + f"Content-Length: {len(duplicate_body)}\r\n".encode("ascii")
                + b"\r\n"
                + duplicate_body
            )
        )
        self.assertEqual(duplicate_status, 400)

        malformed_status, _, _ = await self.raw_request(
            (
                b"POST /v1/mailbox/fetch HTTP/1.1\r\n"
                b"Host: localhost\r\n"
                b"Content-Type: application/json\r\n"
                b"Content-Length: 1\r\n\r\n["
            )
        )
        self.assertEqual(malformed_status, 400)

        duplicate_header_status, _, _ = await self.raw_request(
            (
                b"POST /v1/mailbox/fetch HTTP/1.1\r\n"
                b"Host: localhost\r\n"
                b"Content-Type: application/json\r\n"
                b"Content-Length: 2\r\n"
                b"Content-Length: 2\r\n\r\n{}"
            )
        )
        self.assertEqual(duplicate_header_status, 400)

        oversized_header_status, oversized_header, _ = await self.raw_request(
            b"X" * 20_000
        )
        self.assertEqual(oversized_header_status, 431)
        self.assertEqual(oversized_header["error"], "headersTooLarge")

        oversized_status, oversized, _ = await self.raw_request(
            (
                b"POST /v1/mailbox/put HTTP/1.1\r\n"
                b"Host: localhost\r\n"
                b"Content-Type: application/json\r\n"
                + f"Content-Length: {MAX_MAILBOX_REQUEST_BYTES + 1}\r\n".encode(
                    "ascii"
                )
                + b"\r\n"
            )
        )
        self.assertEqual(oversized_status, 413)
        self.assertEqual(oversized["error"], "requestTooLarge")

    async def test_mailbox_connection_limit_bounds_slow_requests_and_recovers(
        self,
    ) -> None:
        await self.relay.close()
        self.relay = RelayServer(
            port=0,
            metrics_port=0,
            mailbox_port=0,
            mailbox_database_path=self.database_path,
            mailbox_max_connections=1,
        )
        await self.relay.start()

        _, first_writer = await asyncio.open_connection(
            "127.0.0.1",
            self.relay.bound_mailbox_port,
        )
        first_writer.write(b"POST /v1/mailbox/fetch HTTP/1.1\r\n")
        await first_writer.drain()
        async with asyncio.timeout(1):
            while len(self.relay._mailbox_tasks) != 1:
                await asyncio.sleep(0)

        second_reader, second_writer = await asyncio.open_connection(
            "127.0.0.1",
            self.relay.bound_mailbox_port,
        )
        self.assertEqual(await asyncio.wait_for(second_reader.read(), 1), b"")
        self.assertEqual(len(self.relay._mailbox_tasks), 1)
        self.assertEqual(
            self.relay.service.metrics.snapshot()["counters"][
                "mailbox_connection_capacity_rejections"
            ],
            1,
        )
        second_writer.close()
        await second_writer.wait_closed()

        first_writer.close()
        await first_writer.wait_closed()
        async with asyncio.timeout(1):
            while self.relay._mailbox_tasks:
                await asyncio.sleep(0)

        _, credentials = self.credentials(26)
        status, _, _ = await self.request_json(
            "/v1/mailbox/fetch",
            {**credentials, "after": 0},
        )
        self.assertEqual(status, 200)

    async def test_metrics_are_aggregate_and_contain_no_mailbox_secrets(self) -> None:
        _, credentials = self.credentials(16)
        message_id = encode_base64url(key(110))
        payload = encode_base64url(b"private-payload-marker")
        status, _, _ = await self.request_json(
            "/v1/mailbox/put",
            {
                **credentials,
                "messages": [{"id": message_id, "payload": payload}],
            },
        )
        self.assertEqual(status, 200)

        metrics_status, metrics, raw_metrics = await self.raw_request(
            (
                b"GET /metrics HTTP/1.1\r\n"
                b"Host: localhost\r\n"
                b"Content-Length: 0\r\n"
                b"Connection: close\r\n\r\n"
            ),
            metrics=True,
        )
        self.assertEqual(metrics_status, 200)
        self.assertEqual(metrics["counters"]["mailbox_messages_put"], 1)
        for secret in (*credentials.values(), message_id, payload):
            self.assertNotIn(secret.encode("ascii"), raw_metrics)
        self.assertNotIn(b"private-payload-marker", raw_metrics)
        self.assertNotIn(b"127.0.0.1", raw_metrics)

    async def test_startup_and_periodic_tasks_delete_expired_rows(self) -> None:
        await self.relay.close()
        clock = FakeClock()
        route = mailbox_route_for_auth(key(23))
        with MailboxStore(
            self.database_path,
            retention_seconds=10,
            clock=clock,
        ) as store:
            store.put(route, [put_message(140, b"startup")])
        clock.value += 10

        self.relay = RelayServer(
            port=0,
            metrics_port=0,
            mailbox_port=0,
            mailbox_database_path=self.database_path,
            mailbox_retention_seconds=10,
            mailbox_purge_interval_seconds=0.01,
            mailbox_clock=clock,
        )
        await self.relay.start()

        def receipt_count() -> int:
            with closing(
                sqlite3.connect(self.database_path)
            ) as connection:
                return int(
                    connection.execute(
                        "SELECT COUNT(*) FROM mailbox_messages"
                    ).fetchone()[0]
                )

        self.assertEqual(await asyncio.to_thread(receipt_count), 0)
        await asyncio.to_thread(
            self.relay.mailbox.put,
            route,
            [put_message(141, b"periodic")],
        )
        self.assertEqual(await asyncio.to_thread(receipt_count), 1)
        clock.value += 10

        async with asyncio.timeout(1):
            while await asyncio.to_thread(receipt_count) != 0:
                await asyncio.sleep(0.01)


if __name__ == "__main__":
    unittest.main()
