from __future__ import annotations

import asyncio
import base64
import contextlib
import io
import json
import os
import ssl
import subprocess
import tempfile
import unittest
from collections.abc import Awaitable, Callable
from typing import Any

from websockets.asyncio.client import ClientConnection, connect
from websockets.exceptions import ConnectionClosed, InvalidMessage

from gotsync_server.server import (
    MAX_FORWARD_QUEUE_BYTES,
    MAX_FORWARD_QUEUE_FRAMES,
    MAX_REGISTRATION_BYTES,
    BoundedOutboundQueue,
    Metrics,
    RegistrationError,
    RelayServer,
    main,
    parse_registration,
    server_tls_context,
)


def self_signed_certificate(directory: str) -> tuple[str, str]:
    certificate = os.path.join(directory, "tls.crt")
    key = os.path.join(directory, "tls.key")
    subprocess.run(
        [
            "openssl", "req", "-x509", "-newkey", "ec",
            "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes",
            "-days", "1", "-subj", "/CN=127.0.0.1",
            "-keyout", key, "-out", certificate,
        ],
        check=True,
        capture_output=True,
    )
    return certificate, key


def route_text(seed: int) -> str:
    raw = bytes((seed + offset) % 256 for offset in range(32))
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def registration(route: str) -> str:
    return json.dumps(
        {"route": route, "type": "register", "version": 2},
        separators=(",", ":"),
        sort_keys=True,
    )


async def wait_until(
    predicate: Callable[[], bool],
    *,
    timeout: float = 1.0,
) -> None:
    async with asyncio.timeout(timeout):
        while not predicate():
            await asyncio.sleep(0)


class RegistrationTests(unittest.TestCase):
    def test_accepts_only_canonical_32_byte_route(self) -> None:
        route = route_text(7)
        self.assertEqual(parse_registration(registration(route)), bytes(range(7, 39)))

        invalid_routes = (
            route + "=",
            route[:-1],
            route[:-1] + "+",
            base64.urlsafe_b64encode(bytes(31)).rstrip(b"=").decode("ascii"),
        )
        for invalid_route in invalid_routes:
            with self.subTest(route=invalid_route):
                with self.assertRaises(RegistrationError):
                    parse_registration(registration(invalid_route))

    def test_rejects_binary_duplicate_unknown_and_oversized_registration(self) -> None:
        route = route_text(1)
        invalid_messages: tuple[str | bytes, ...] = (
            registration(route).encode("utf-8"),
            (
                '{"type":"register","type":"register","version":2,"route":"'
                + route
                + '"}'
            ),
            json.dumps(
                {
                    "extra": False,
                    "route": route,
                    "type": "register",
                    "version": 2,
                }
            ),
            json.dumps(
                {"route": route, "type": "register", "version": True}
            ),
            " " * (MAX_REGISTRATION_BYTES + 1),
        )
        for message in invalid_messages:
            with self.subTest(message_type=type(message).__name__):
                with self.assertRaises(RegistrationError):
                    parse_registration(message)


class MetricsTests(unittest.TestCase):
    def test_reset_clears_counters_but_preserves_gauges(self) -> None:
        metrics = Metrics()
        metrics.increment("binary_frames_forwarded", 3)
        metrics.increment("binary_bytes_forwarded", 42)
        metrics.set_active(connections=2, rooms=1)

        metrics.reset_counters()

        snapshot = metrics.snapshot()
        self.assertTrue(all(value == 0 for value in snapshot["counters"].values()))
        self.assertEqual(
            snapshot["gauges"],
            {"active_connections": 2, "active_rooms": 1},
        )


class QueueTests(unittest.IsolatedAsyncioTestCase):
    async def test_queue_enforces_frame_and_byte_limits(self) -> None:
        queue = BoundedOutboundQueue()
        for _ in range(MAX_FORWARD_QUEUE_FRAMES):
            self.assertTrue(queue.enqueue(b"x", forwarded_binary=True))
        self.assertFalse(queue.enqueue(b"x", forwarded_binary=True))
        self.assertEqual(queue.frame_count, MAX_FORWARD_QUEUE_FRAMES)

        for _ in range(MAX_FORWARD_QUEUE_FRAMES):
            await queue.dequeue()
        self.assertEqual(queue.frame_count, 0)
        self.assertEqual(queue.byte_count, 0)

        self.assertTrue(
            queue.enqueue(
                b"x" * MAX_FORWARD_QUEUE_BYTES,
                forwarded_binary=True,
            )
        )
        self.assertFalse(queue.enqueue(b"x", forwarded_binary=True))


class RelayIntegrationTests(unittest.IsolatedAsyncioTestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.certificate_directory = tempfile.TemporaryDirectory()
        cls.certificate, cls.key = self_signed_certificate(
            cls.certificate_directory.name
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls.certificate_directory.cleanup()

    async def asyncSetUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.database_path = os.path.join(
            self.temporary_directory.name,
            "mls.sqlite3",
        )
        self.relay = RelayServer(
            port=0,
            metrics_port=0,
            delivery_port=0,
            delivery_database_path=self.database_path,
        )
        await self.relay.start()
        self.clients: list[ClientConnection] = []

    async def asyncTearDown(self) -> None:
        await asyncio.gather(
            *(client.close() for client in self.clients),
            return_exceptions=True,
        )
        await self.relay.close()
        self.temporary_directory.cleanup()

    async def open_client(self, path: str = "/v2/pairing") -> ClientConnection:
        client = await connect(
            f"ws://127.0.0.1:{self.relay.websocket_port}{path}",
            compression=None,
            max_size=512 * 1024,
            open_timeout=2,
            close_timeout=2,
        )
        self.clients.append(client)
        return client

    async def restart_relay(self, **limits: Any) -> None:
        await self.relay.close()
        self.relay = RelayServer(
            port=0,
            metrics_port=0,
            delivery_port=0,
            delivery_database_path=self.database_path,
            **limits,
        )
        await self.relay.start()

    async def registered_pair(
        self, route: str
    ) -> tuple[ClientConnection, ClientConnection]:
        first = await self.open_client()
        await first.send(registration(route))
        second = await self.open_client()
        await second.send(registration(route))
        self.assertEqual(
            json.loads(await asyncio.wait_for(first.recv(), 1))["type"],
            "peerReady",
        )
        self.assertEqual(
            json.loads(await asyncio.wait_for(second.recv(), 1))["type"],
            "peerReady",
        )
        return first, second

    async def http_request(
        self, method: str, target: str
    ) -> tuple[int, dict[str, Any], bytes]:
        reader, writer = await asyncio.open_connection(
            "127.0.0.1", self.relay.bound_metrics_port
        )
        writer.write(
            (
                f"{method} {target} HTTP/1.1\r\n"
                "Host: localhost\r\n"
                "Content-Length: 0\r\n"
                "Connection: close\r\n"
                "\r\n"
            ).encode("ascii")
        )
        await writer.drain()
        response = await asyncio.wait_for(reader.read(), 1)
        writer.close()
        await writer.wait_closed()
        head, body = response.split(b"\r\n\r\n", 1)
        status = int(head.split(b" ", 2)[1])
        return status, json.loads(body), response

    async def test_no_pre_peer_delivery_then_low_latency_forwarding(self) -> None:
        route = route_text(11)
        first = await self.open_client()
        await first.send(registration(route))
        await first.send(b"must-not-be-buffered")
        await wait_until(
            lambda: self.relay.service.metrics.snapshot()["counters"][
                "binary_frames_dropped_no_peer"
            ]
            == 1
        )

        second = await self.open_client()
        await second.send(registration(route))
        self.assertEqual(json.loads(await first.recv())["type"], "peerReady")
        self.assertEqual(json.loads(await second.recv())["type"], "peerReady")

        with self.assertRaises(TimeoutError):
            await asyncio.wait_for(second.recv(), 0.05)

        await first.send(b"live")
        self.assertEqual(await asyncio.wait_for(second.recv(), 1), b"live")
        await second.send(b"return")
        self.assertEqual(await asyncio.wait_for(first.recv(), 1), b"return")

    async def test_capacity_rejection_does_not_disrupt_existing_pair(self) -> None:
        route = route_text(29)
        first, second = await self.registered_pair(route)
        third = await self.open_client()
        await third.send(registration(route))

        error = json.loads(await asyncio.wait_for(third.recv(), 1))
        self.assertEqual(error, {"code": "routeFull", "type": "error", "version": 2})
        with self.assertRaises(ConnectionClosed) as closed:
            await third.recv()
        self.assertEqual(closed.exception.rcvd.code, 1008)

        await first.send(b"still-live")
        self.assertEqual(await asyncio.wait_for(second.recv(), 1), b"still-live")
        counters = self.relay.service.metrics.snapshot()["counters"]
        self.assertEqual(counters["route_capacity_rejections"], 1)

    async def test_total_connection_cap_rejects_and_recovers_capacity(self) -> None:
        await self.restart_relay(
            max_connections=2,
            max_rooms=2,
            waiting_room_ttl=1,
        )
        first = await self.open_client()
        second = await self.open_client()
        await wait_until(lambda: self.relay.service.live_connection_count == 2)

        rejected = await self.open_client()
        self.assertEqual(
            json.loads(await asyncio.wait_for(rejected.recv(), 1)),
            {"code": "relayBusy", "type": "error", "version": 2},
        )
        with self.assertRaises(ConnectionClosed) as closed:
            await rejected.recv()
        self.assertEqual(closed.exception.rcvd.code, 1013)
        self.assertEqual(self.relay.service.live_connection_count, 2)

        await first.close()
        await wait_until(lambda: self.relay.service.live_connection_count == 1)
        replacement = await self.open_client()
        await replacement.send(registration(route_text(41)))
        await wait_until(
            lambda: self.relay.service.live_connection_count == 2
            and self.relay.service.room_count == 1
        )
        counters = self.relay.service.metrics.snapshot()["counters"]
        self.assertEqual(counters["connection_capacity_rejections"], 1)

        await second.close()

    async def test_room_cap_rejects_then_waiting_expiry_frees_room(self) -> None:
        await self.restart_relay(
            max_connections=3,
            max_rooms=1,
            waiting_room_ttl=0.1,
        )
        waiting = await self.open_client()
        await waiting.send(registration(route_text(51)))
        await wait_until(lambda: self.relay.service.room_count == 1)

        rejected = await self.open_client()
        await rejected.send(registration(route_text(52)))
        self.assertEqual(
            json.loads(await asyncio.wait_for(rejected.recv(), 1)),
            {"code": "relayBusy", "type": "error", "version": 2},
        )
        with self.assertRaises(ConnectionClosed) as closed:
            await rejected.recv()
        self.assertEqual(closed.exception.rcvd.code, 1013)

        self.assertEqual(
            json.loads(await asyncio.wait_for(waiting.recv(), 1)),
            {"code": "waitingExpired", "type": "error", "version": 2},
        )
        with self.assertRaises(ConnectionClosed) as expired:
            await waiting.recv()
        self.assertEqual(expired.exception.rcvd.code, 1008)
        await wait_until(
            lambda: self.relay.service.room_count == 0
            and self.relay.service.connection_count == 0
        )

        replacement = await self.open_client()
        await replacement.send(registration(route_text(52)))
        await wait_until(lambda: self.relay.service.room_count == 1)
        counters = self.relay.service.metrics.snapshot()["counters"]
        self.assertEqual(counters["room_capacity_rejections"], 1)
        self.assertEqual(counters["waiting_room_expirations"], 1)

    async def test_waiting_ttl_pauses_for_pair_and_restarts_on_peer_left(self) -> None:
        await self.restart_relay(
            max_connections=4,
            max_rooms=2,
            waiting_room_ttl=0.1,
        )
        first, second = await self.registered_pair(route_text(61))
        await asyncio.sleep(0.15)
        await first.send(b"paired-after-ttl")
        self.assertEqual(
            await asyncio.wait_for(second.recv(), 1),
            b"paired-after-ttl",
        )

        await second.close()
        self.assertEqual(
            json.loads(await asyncio.wait_for(first.recv(), 1)),
            {"type": "peerLeft", "version": 2},
        )
        self.assertEqual(
            json.loads(await asyncio.wait_for(first.recv(), 1)),
            {"code": "waitingExpired", "type": "error", "version": 2},
        )
        with self.assertRaises(ConnectionClosed) as expired:
            await first.recv()
        self.assertEqual(expired.exception.rcvd.code, 1008)
        await wait_until(
            lambda: self.relay.service.room_count == 0
            and self.relay.service.connection_count == 0
        )

    async def test_peer_left_and_empty_room_cleanup(self) -> None:
        route = route_text(73)
        first, second = await self.registered_pair(route)
        await second.close()

        peer_left = json.loads(await asyncio.wait_for(first.recv(), 1))
        self.assertEqual(peer_left, {"type": "peerLeft", "version": 2})
        await first.close()
        await wait_until(lambda: self.relay.service.room_count == 0)
        self.assertEqual(self.relay.service.connection_count, 0)
        self.assertEqual(
            self.relay.service.metrics.snapshot()["gauges"],
            {"active_connections": 0, "active_rooms": 0},
        )

        replacement = await self.open_client()
        await replacement.send(registration(route))
        await wait_until(lambda: self.relay.service.connection_count == 1)
        self.assertEqual(self.relay.service.room_count, 1)

    async def test_only_generic_path_and_binary_frames_are_accepted(self) -> None:
        for path in ("/v2/pairing?route=leak", "/v1"):
            with self.subTest(path=path):
                wrong_path = await self.open_client(path)
                with self.assertRaises(ConnectionClosed) as path_close:
                    await wrong_path.recv()
                self.assertEqual(path_close.exception.rcvd.code, 1008)

        route = route_text(90)
        first, _ = await self.registered_pair(route)
        await first.send("plaintext-after-registration")
        with self.assertRaises(ConnectionClosed) as text_close:
            await first.recv()
        self.assertEqual(text_close.exception.rcvd.code, 1003)

    async def test_websocket_compression_is_not_negotiated(self) -> None:
        client = await connect(
            f"ws://127.0.0.1:{self.relay.websocket_port}/v2/pairing",
            compression="deflate",
        )
        self.clients.append(client)
        self.assertEqual(client.protocol.extensions, [])

    async def test_invalid_first_frame_is_rejected_without_creating_room(self) -> None:
        client = await self.open_client()
        await client.send(b"binary-registration")
        with self.assertRaises(ConnectionClosed) as closed:
            await client.recv()
        self.assertEqual(closed.exception.rcvd.code, 1008)
        self.assertEqual(self.relay.service.room_count, 0)
        self.assertEqual(self.relay.service.connection_count, 0)
        counters = self.relay.service.metrics.snapshot()["counters"]
        self.assertEqual(counters["registrations_rejected"], 1)

    async def test_aggregate_metrics_health_and_reset_have_no_identifiers(self) -> None:
        route = route_text(105)
        first, second = await self.registered_pair(route)
        await first.send(b"private-payload-marker")
        self.assertEqual(await second.recv(), b"private-payload-marker")
        await wait_until(
            lambda: self.relay.service.metrics.snapshot()["counters"][
                "binary_frames_forwarded"
            ]
            == 1
        )

        health_status, health, _ = await self.http_request("GET", "/healthz")
        self.assertEqual(health_status, 200)
        self.assertEqual(health, {"status": "ok", "version": 2, "supportedVersions": [2]})

        ready_status, ready, _ = await self.http_request("GET", "/readyz")
        self.assertEqual(ready_status, 200)
        self.assertEqual(ready, {"status": "ready", "version": 2})

        status, metrics, raw_metrics = await self.http_request("GET", "/metrics")
        self.assertEqual(status, 200)
        self.assertEqual(metrics["gauges"]["active_connections"], 2)
        self.assertEqual(metrics["gauges"]["active_rooms"], 1)
        self.assertEqual(metrics["counters"]["binary_frames_forwarded"], 1)
        self.assertEqual(metrics["counters"]["binary_bytes_forwarded"], 22)
        self.assertNotIn(route.encode("ascii"), raw_metrics)
        self.assertNotIn(b"private-payload-marker", raw_metrics)
        self.assertNotIn(b"127.0.0.1", raw_metrics)

        reset_status, reset_metrics, _ = await self.http_request(
            "POST", "/metrics/reset"
        )
        self.assertEqual(reset_status, 200)
        self.assertTrue(
            all(value == 0 for value in reset_metrics["counters"].values())
        )
        self.assertEqual(
            reset_metrics["gauges"],
            {"active_connections": 2, "active_rooms": 1},
        )

    async def test_relay_creates_no_files(self) -> None:
        route = route_text(131)
        with tempfile.TemporaryDirectory() as temporary_directory:
            previous_directory = os.getcwd()
            os.chdir(temporary_directory)
            try:
                first, second = await self.registered_pair(route)
                await first.send(b"transient")
                self.assertEqual(await second.recv(), b"transient")
            finally:
                os.chdir(previous_directory)
            self.assertEqual(os.listdir(temporary_directory), [])

    async def test_oversized_binary_message_is_closed(self) -> None:
        route = route_text(167)
        first, _ = await self.registered_pair(route)
        await first.send(b"x" * (512 * 1024 + 1))
        with self.assertRaises(ConnectionClosed) as closed:
            await first.recv()
        self.assertEqual(closed.exception.rcvd.code, 1009)

    async def test_graceful_shutdown_closes_sockets_and_cleans_rooms(self) -> None:
        first, second = await self.registered_pair(route_text(201))
        await self.relay.close()

        for client in (first, second):
            with self.assertRaises(ConnectionClosed):
                await client.recv()
        self.assertEqual(self.relay.service.room_count, 0)
        self.assertEqual(self.relay.service.connection_count, 0)
        self.assertEqual(
            self.relay.service.metrics.snapshot()["gauges"],
            {"active_connections": 0, "active_rooms": 0},
        )

    async def test_metrics_listener_rejects_non_loopback_bind(self) -> None:
        with self.assertRaisesRegex(ValueError, "loopback"):
            RelayServer(metrics_host="0.0.0.0")

    async def test_plaintext_listeners_reject_non_loopback_binds(
        self,
    ) -> None:
        for options in (
            {"host": "0.0.0.0"},
            {"delivery_host": "0.0.0.0"},
        ):
            with self.subTest(options=options):
                with self.assertRaisesRegex(ValueError, "without TLS"):
                    RelayServer(**options)

    async def test_tls_listeners_accept_non_loopback_binds(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            relay = RelayServer(
                host="0.0.0.0",
                delivery_host="0.0.0.0",
                delivery_database_path=os.path.join(
                    temporary_directory,
                    "mls.sqlite3",
                ),
                tls=server_tls_context(self.certificate, self.key),
            )
            await relay.close()

    async def test_tls_listeners_serve_only_tls(self) -> None:
        await self.restart_relay(tls=server_tls_context(self.certificate, self.key))
        client_tls = ssl.create_default_context(cafile=self.certificate)
        client_tls.check_hostname = False

        client = await connect(
            f"wss://127.0.0.1:{self.relay.websocket_port}/v2/pairing",
            ssl=client_tls,
            open_timeout=2,
        )
        await client.close()
        with self.assertRaises(InvalidMessage):
            await connect(
                f"ws://127.0.0.1:{self.relay.websocket_port}/v2/pairing",
                open_timeout=2,
            )

        reader, writer = await asyncio.open_connection(
            "127.0.0.1", self.relay.bound_delivery_port, ssl=client_tls
        )
        writer.write(b"GET /healthz HTTP/1.1\r\nHost: relay\r\n\r\n")
        await writer.drain()
        status_line = await asyncio.wait_for(reader.readline(), 2)
        writer.close()
        await writer.wait_closed()
        self.assertEqual(status_line.split()[1], b"404")

        reader, writer = await asyncio.open_connection(
            "127.0.0.1", self.relay.bound_delivery_port
        )
        writer.write(b"GET /healthz HTTP/1.1\r\nHost: relay\r\n\r\n")
        await writer.drain()
        self.assertEqual(await asyncio.wait_for(reader.read(), 2), b"")
        writer.close()
        await writer.wait_closed()

    def test_cli_requires_certificate_and_key_together(self) -> None:
        for arguments in (["--tls-cert", "cert.pem"], ["--tls-key", "key.pem"]):
            with self.subTest(arguments=arguments):
                with contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit):
                        main(arguments)

    def test_cli_rejects_unreadable_certificate(self) -> None:
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            with self.assertRaises(SystemExit):
                main(["--tls-cert", "/missing/tls.crt", "--tls-key", self.key])
        self.assertIn("cannot load TLS certificate /missing/tls.crt", stderr.getvalue())

    async def test_readiness_reports_closed_delivery_store(self) -> None:
        self.relay.mls.store.close()
        status, document, _ = await self.http_request("GET", "/readyz")
        self.assertEqual(status, 503)
        self.assertEqual(
            document,
            {"status": "unavailable", "version": 2},
        )

    async def test_delivery_listener_serves_only_mls_paths(self) -> None:
        for target in ("/v1/mailbox/fetch", "/v2/mailbox/fetch", "/v2/mls"):
            with self.subTest(target=target):
                reader, writer = await asyncio.open_connection(
                    "127.0.0.1", self.relay.bound_delivery_port
                )
                writer.write(
                    (
                        f"POST {target} HTTP/1.1\r\n"
                        "Host: localhost\r\n"
                        "Content-Type: application/json\r\n"
                        "Content-Length: 13\r\n"
                        "\r\n"
                        '{"version":2}'
                    ).encode("ascii")
                )
                await writer.drain()
                response = await asyncio.wait_for(reader.read(), 1)
                writer.close()
                await writer.wait_closed()
                head, body = response.split(b"\r\n\r\n", 1)
                self.assertTrue(head.startswith(b"HTTP/1.1 404 "))
                self.assertEqual(
                    json.loads(body), {"error": "notFound", "version": 2}
                )
