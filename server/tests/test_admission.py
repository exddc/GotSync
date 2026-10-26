from __future__ import annotations

import asyncio
import base64
import ipaddress
import json
import os
import tempfile
import unittest
from pathlib import Path
from typing import Any

from websockets.asyncio.client import connect
from websockets.exceptions import ConnectionClosed, InvalidStatus

from gotsync_server.admission import (
    AdmissionConfig,
    AdmissionController,
    ConcurrencyLimiter,
    RateLimit,
    TokenBucketLimiter,
    read_admission_tokens,
)
from gotsync_server.http import encode_base64url
from gotsync_server.server import (
    ADMISSION_TOKEN_FILE_ENVIRONMENT,
    RelayServer,
    _argument_parser,
    admission_config_from_arguments,
)

TOKEN = "t" * 40
NO_RATE_LIMIT = RateLimit(0, 0)


class FakeClock:
    def __init__(self, value: float = 1_000.0) -> None:
        self.value = value

    def __call__(self) -> float:
        return self.value


def network(value: str) -> ipaddress.IPv4Network | ipaddress.IPv6Network:
    return ipaddress.ip_network(value)


def route_text(seed: int) -> str:
    raw = bytes((seed + offset) % 256 for offset in range(32))
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def registration(route: str) -> str:
    return json.dumps(
        {"route": route, "type": "register", "version": 2},
        separators=(",", ":"),
        sort_keys=True,
    )


class TokenBucketTests(unittest.TestCase):
    def test_burst_then_refill_and_rejections_do_not_drain(self) -> None:
        clock = FakeClock()
        limiter = TokenBucketLimiter(RateLimit(2, 3), clock=clock)
        for _ in range(3):
            self.assertIsNone(limiter.acquire("a"))
        self.assertAlmostEqual(limiter.acquire("a") or 0, 0.5)
        self.assertAlmostEqual(limiter.acquire("a") or 0, 0.5)
        self.assertIsNone(limiter.acquire("b"))

        clock.value += 0.5
        self.assertIsNone(limiter.acquire("a"))
        self.assertIsNotNone(limiter.acquire("a"))

    def test_tracked_sources_are_bounded(self) -> None:
        limiter = TokenBucketLimiter(RateLimit(1, 1), max_sources=3, clock=FakeClock())
        for index in range(100):
            limiter.acquire(f"source-{index}")
        self.assertEqual(limiter.tracked_sources, 3)

    def test_disabled_limit_tracks_nothing(self) -> None:
        limiter = TokenBucketLimiter(NO_RATE_LIMIT)
        for _ in range(1000):
            self.assertIsNone(limiter.acquire("a"))
        self.assertEqual(limiter.tracked_sources, 0)

    def test_rate_limit_rejects_inconsistent_values(self) -> None:
        for rate, burst in ((-1, 1), (1, 0), (0, 1), (float("inf"), 1)):
            with self.subTest(rate=rate, burst=burst):
                with self.assertRaises(ValueError):
                    RateLimit(rate, burst)


class ConcurrencyLimiterTests(unittest.TestCase):
    def test_limits_and_forgets_idle_sources(self) -> None:
        limiter = ConcurrencyLimiter(2)
        self.assertTrue(limiter.acquire("a"))
        self.assertTrue(limiter.acquire("a"))
        self.assertFalse(limiter.acquire("a"))
        self.assertTrue(limiter.acquire("b"))
        limiter.release("a")
        self.assertTrue(limiter.acquire("a"))
        for source in ("a", "a", "b"):
            limiter.release(source)
        self.assertEqual(limiter.tracked_sources, 0)


class SourceResolutionTests(unittest.TestCase):
    def test_forwarded_header_is_ignored_without_trusted_proxy(self) -> None:
        controller = AdmissionController()
        source = controller.resolve_source(
            ("203.0.113.9", 4000), {"x-forwarded-for": "198.51.100.1"}
        )
        self.assertEqual(source.key, "203.0.113.9")

    def test_trusted_proxy_chain_uses_rightmost_untrusted_hop(self) -> None:
        controller = AdmissionController(
            AdmissionConfig(trusted_proxies=(network("10.0.0.0/8"),))
        )
        headers = {"x-forwarded-for": "192.0.2.66, 198.51.100.7, 10.1.1.1"}
        source = controller.resolve_source(("10.0.0.2", 4000), headers)
        self.assertEqual(source.key, "198.51.100.7")

        missing = controller.resolve_source(("10.0.0.2", 4000), {})
        self.assertEqual(missing.key, "10.0.0.2")
        invalid = controller.resolve_source(
            ("10.0.0.2", 4000), {"x-forwarded-for": "198.51.100.7, garbage"}
        )
        self.assertEqual(invalid.key, "10.0.0.2")

    def test_custom_header_and_ipv6_prefix_grouping(self) -> None:
        controller = AdmissionController(
            AdmissionConfig(
                trusted_proxies=(network("::1/128"),),
                client_ip_header="X-Real-IP",
            )
        )
        first = controller.resolve_source(
            ("::1", 4000, 0, 0), {"x-real-ip": "2001:db8:1:2::1"}
        )
        second = controller.resolve_source(
            ("::1", 4000, 0, 0), {"x-real-ip": "2001:db8:1:2:ffff::9"}
        )
        self.assertEqual(first.key, "2001:db8:1:2::/64")
        self.assertEqual(first.key, second.key)
        mapped = controller.resolve_source(("::ffff:192.0.2.1", 1, 0, 0), None)
        self.assertEqual(mapped.key, "192.0.2.1")

    def test_unknown_peer_shares_one_source(self) -> None:
        controller = AdmissionController()
        self.assertEqual(controller.resolve_source(None, None).key, "unknown")


class AdmissionTests(unittest.TestCase):
    def test_token_is_required_when_configured(self) -> None:
        controller = AdmissionController(AdmissionConfig.with_tokens([TOKEN]))
        source = controller.resolve_source(("127.0.0.1", 1), None)
        self.assertEqual(controller.admit(source, {}).status, 403)  # type: ignore[union-attr]
        self.assertIsNotNone(
            controller.admit(source, {"x-gotsync-admission": TOKEN + "x"})
        )
        self.assertIsNone(controller.admit(source, {"x-gotsync-admission": TOKEN}))

    def test_allowlist_restricts_client_networks(self) -> None:
        controller = AdmissionController(
            AdmissionConfig(allowed_networks=(network("100.64.0.0/10"),))
        )
        allowed = controller.resolve_source(("100.64.1.2", 1), None)
        denied = controller.resolve_source(("203.0.113.1", 1), None)
        self.assertIsNone(controller.admit(allowed, None))
        self.assertEqual(controller.admit(denied, None).code, "admissionDenied")  # type: ignore[union-attr]

    def test_short_tokens_are_rejected_without_echoing_them(self) -> None:
        with self.assertRaises(ValueError) as raised:
            AdmissionConfig.with_tokens(["short-secret"])
        self.assertNotIn("short-secret", str(raised.exception))

    def test_token_file_and_environment_configuration(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "tokens"
            path.write_text(f"# operator tokens\n\n{TOKEN}\n{'u' * 32}\n")
            self.assertEqual(read_admission_tokens(path), [TOKEN, "u" * 32])

            args = _argument_parser().parse_args(
                ["--trusted-proxy", "10.0.0.0/8", "--admission-allow", "100.64.0.0/10"]
            )
            config = admission_config_from_arguments(
                args, {ADMISSION_TOKEN_FILE_ENVIRONMENT: str(path)}
            )
            self.assertEqual(len(config.admission_token_digests), 2)
            self.assertEqual(config.trusted_proxies, (network("10.0.0.0/8"),))
            self.assertEqual(config.allowed_networks, (network("100.64.0.0/10"),))
            self.assertNotIn(TOKEN, repr(config))

            empty = Path(directory) / "empty"
            empty.write_text("# none\n")
            with self.assertRaises(ValueError):
                read_admission_tokens(empty)

    def test_defaults_require_no_admission(self) -> None:
        args = _argument_parser().parse_args([])
        config = admission_config_from_arguments(args, {})
        self.assertFalse(config.requires_admission)
        self.assertEqual(config.trusted_proxies, ())
        self.assertTrue(config.http_requests.enabled)
        self.assertTrue(config.websocket_connects.enabled)


class RelayAdmissionTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.database_path = os.path.join(self.temporary_directory.name, "mls.sqlite3")
        self.clock = FakeClock()
        self.relay: RelayServer | None = None

    async def asyncTearDown(self) -> None:
        if self.relay is not None:
            await self.relay.close()
        self.temporary_directory.cleanup()

    async def start(self, config: AdmissionConfig, **options: Any) -> RelayServer:
        self.relay = RelayServer(
            port=0,
            metrics_port=0,
            delivery_port=0,
            delivery_database_path=self.database_path,
            admission=config,
            admission_clock=self.clock,
            **options,
        )
        await self.relay.start()
        return self.relay

    def counters(self) -> dict[str, int]:
        assert self.relay is not None
        return self.relay.service.metrics.snapshot()["counters"]

    async def post(
        self,
        target: str,
        document: dict[str, Any],
        headers: dict[str, str] | None = None,
    ) -> tuple[int, dict[str, str], dict[str, Any]]:
        assert self.relay is not None
        reader, writer = await asyncio.open_connection(
            "127.0.0.1", self.relay.bound_delivery_port
        )
        body = json.dumps(document).encode()
        extra = "".join(f"{name}: {value}\r\n" for name, value in (headers or {}).items())
        writer.write(
            (
                f"POST {target} HTTP/1.1\r\nHost: relay\r\n"
                "Content-Type: application/json\r\n"
                f"Content-Length: {len(body)}\r\n{extra}\r\n"
            ).encode()
            + body
        )
        await writer.drain()
        response = await asyncio.wait_for(reader.read(), 2)
        writer.close()
        await writer.wait_closed()
        head, response_body = response.split(b"\r\n\r\n", 1)
        lines = head.decode().split("\r\n")
        response_headers = {
            name.lower(): value.strip()
            for name, value in (line.split(":", 1) for line in lines[1:])
        }
        return int(lines[0].split()[1]), response_headers, json.loads(response_body)

    async def create(
        self, seed: int, headers: dict[str, str] | None = None
    ) -> tuple[int, dict[str, str], dict[str, Any]]:
        return await self.post(
            "/v2/mls/create",
            {"group": encode_base64url(bytes([seed]) * 32), "version": 2},
            {"Authorization": f"Bearer {encode_base64url(b'a' * 32)}", **(headers or {})},
        )

    def group_count(self) -> int:
        assert self.relay is not None
        return self.relay.mls.store._db.execute("SELECT COUNT(*) FROM mls_groups").fetchone()[0]

    async def test_rate_limit_returns_retry_after_without_storing(self) -> None:
        await self.start(AdmissionConfig(http_requests=RateLimit(1, 2)))
        for seed in (1, 2):
            status, _, _ = await self.create(seed)
            self.assertEqual(status, 200)

        status, headers, body = await self.create(3)
        self.assertEqual(status, 429)
        self.assertEqual(headers["retry-after"], "1")
        self.assertEqual(body, {"error": "rateLimited", "version": 2})
        self.assertEqual(self.group_count(), 2)
        self.assertEqual(self.counters()["rate_limit_rejections"], 1)

        self.clock.value += 1
        status, _, _ = await self.create(3)
        self.assertEqual(status, 200)

    async def test_trusted_proxy_separates_forwarded_clients(self) -> None:
        await self.start(
            AdmissionConfig(
                trusted_proxies=(network("127.0.0.1/32"),),
                http_requests=RateLimit(1, 1),
            )
        )
        first = {"X-Forwarded-For": "198.51.100.1"}
        second = {"X-Forwarded-For": "198.51.100.2"}
        self.assertEqual((await self.create(1, first))[0], 200)
        self.assertEqual((await self.create(2, first))[0], 429)
        self.assertEqual((await self.create(2, second))[0], 200)

    async def test_untrusted_forwarded_header_cannot_evade_limit(self) -> None:
        await self.start(AdmissionConfig(http_requests=RateLimit(1, 1)))
        self.assertEqual(
            (await self.create(1, {"X-Forwarded-For": "198.51.100.1"}))[0],
            200,
        )
        self.assertEqual(
            (await self.create(2, {"X-Forwarded-For": "198.51.100.2"}))[0],
            429,
        )

    async def test_delivery_admission_token_is_required_and_not_exposed(self) -> None:
        relay = await self.start(AdmissionConfig.with_tokens([TOKEN]))
        status, _, body = await self.create(1)
        self.assertEqual((status, body["error"]), (403, "admissionDenied"))
        status, _, _ = await self.create(1, {"X-GotSync-Admission": "x" * 40})
        self.assertEqual(status, 403)
        self.assertEqual(self.counters()["admission_rejections"], 2)
        self.assertEqual(self.group_count(), 0)
        status, _, _ = await self.create(1, {"X-GotSync-Admission": TOKEN})
        self.assertEqual(status, 200)
        snapshot = json.dumps(relay.service.metrics.snapshot())
        self.assertNotIn(TOKEN, snapshot)

    async def test_direct_peer_in_flight_limit_closes_extra_connections(self) -> None:
        relay = await self.start(AdmissionConfig(max_http_requests_per_source=1))
        _, held_writer = await asyncio.open_connection("127.0.0.1", relay.bound_delivery_port)
        held_writer.write(b"POST /v2/mls/create HTTP/1.1\r\n")
        await held_writer.drain()
        await asyncio.sleep(0.05)
        reader, writer = await asyncio.open_connection("127.0.0.1", relay.bound_delivery_port)
        self.assertEqual(await asyncio.wait_for(reader.read(), 2), b"")
        writer.close()
        self.assertEqual(self.counters()["source_concurrency_rejections"], 1)
        held_writer.close()
        await asyncio.sleep(0.05)
        status, _, _ = await self.create(1)
        self.assertEqual(status, 200)
        self.assertEqual(relay.admission.http_in_flight.tracked_sources, 0)

    async def test_proxied_in_flight_limit_returns_429(self) -> None:
        relay = await self.start(
            AdmissionConfig(
                trusted_proxies=(network("127.0.0.1/32"),),
                max_http_requests_per_source=1,
            )
        )
        _, held_writer = await asyncio.open_connection("127.0.0.1", relay.bound_delivery_port)
        held_writer.write(
            b"POST /v2/mls/create HTTP/1.1\r\nX-Forwarded-For: 198.51.100.4\r\n"
            b"Content-Type: application/json\r\nContent-Length: 100\r\n\r\n"
        )
        await held_writer.drain()
        await asyncio.sleep(0.05)
        status, headers, body = await self.create(1, {"X-Forwarded-For": "198.51.100.4"})
        self.assertEqual((status, body["error"], headers["retry-after"]), (429, "rateLimited", "1"))
        status, _, _ = await self.create(1, {"X-Forwarded-For": "198.51.100.5"})
        self.assertEqual(status, 200)
        held_writer.close()

    async def test_proxied_rejections_do_not_wait_for_request_bodies(self) -> None:
        relay = await self.start(
            AdmissionConfig(
                trusted_proxies=(network("127.0.0.1/32"),),
                max_http_requests_per_source=1,
            ),
            delivery_max_connections=4,
        )
        incomplete = (
            b"POST /v2/mls/create HTTP/1.1\r\nX-Forwarded-For: 198.51.100.4\r\n"
            b"Content-Type: application/json\r\nContent-Length: 100\r\n\r\n"
        )
        _, held_writer = await asyncio.open_connection("127.0.0.1", relay.bound_delivery_port)
        held_writer.write(incomplete)
        await held_writer.drain()
        await asyncio.sleep(0.05)
        rejected = [
            await asyncio.open_connection("127.0.0.1", relay.bound_delivery_port)
            for _ in range(3)
        ]
        for _, writer in rejected:
            writer.write(incomplete)
            await writer.drain()
        for reader, writer in rejected:
            response = await asyncio.wait_for(reader.read(), 0.5)
            self.assertTrue(response.startswith(b"HTTP/1.1 429 "))
            writer.close()
        await asyncio.sleep(0.05)
        status, _, _ = await self.create(1, {"X-Forwarded-For": "198.51.100.5"})
        self.assertEqual(status, 200)
        self.assertEqual(self.counters()["source_concurrency_rejections"], 3)
        held_writer.close()

    async def test_websocket_connect_rate_limit_rejects_handshake(self) -> None:
        relay = await self.start(AdmissionConfig(websocket_connects=RateLimit(1, 1)))
        url = f"ws://127.0.0.1:{relay.websocket_port}/v2/pairing"
        async with connect(url, open_timeout=2) as first:
            await first.send(registration(route_text(1)))
            with self.assertRaises(InvalidStatus) as rejected:
                await connect(url, open_timeout=2)
            response = rejected.exception.response
            self.assertEqual(response.status_code, 429)
            self.assertEqual(response.headers["Retry-After"], "1")
            self.assertEqual(relay.service.live_connection_count, 1)
            self.assertEqual(relay.service.room_count, 1)
        self.assertEqual(self.counters()["rate_limit_rejections"], 1)
        self.clock.value += 1
        async with connect(url, open_timeout=2):
            pass

    async def test_websocket_per_source_limit_closes_with_try_again_later(self) -> None:
        relay = await self.start(AdmissionConfig(max_websockets_per_source=1))
        url = f"ws://127.0.0.1:{relay.websocket_port}/v2/pairing"
        async with connect(url, open_timeout=2) as first:
            await first.send(registration(route_text(2)))
            async with connect(url, open_timeout=2) as second:
                error = json.loads(await asyncio.wait_for(second.recv(), 1))
                self.assertEqual(error, {"code": "rateLimited", "type": "error", "version": 2})
                with self.assertRaises(ConnectionClosed) as closed:
                    await second.recv()
                self.assertEqual(closed.exception.rcvd.code, 1013)
            self.assertEqual(relay.service.live_connection_count, 1)
        self.assertEqual(self.counters()["source_concurrency_rejections"], 1)

    async def test_websocket_admission_token(self) -> None:
        relay = await self.start(AdmissionConfig.with_tokens([TOKEN]))
        url = f"ws://127.0.0.1:{relay.websocket_port}/v2/pairing"
        with self.assertRaises(InvalidStatus) as rejected:
            await connect(url, open_timeout=2)
        self.assertEqual(rejected.exception.response.status_code, 403)
        self.assertNotIn(TOKEN.encode(), rejected.exception.response.body or b"")
        async with connect(
            url, open_timeout=2, additional_headers={"X-GotSync-Admission": TOKEN}
        ) as admitted:
            await admitted.send(registration(route_text(3)))
            await asyncio.sleep(0.05)
            self.assertEqual(relay.service.room_count, 1)
        self.assertEqual(self.counters()["admission_rejections"], 1)
