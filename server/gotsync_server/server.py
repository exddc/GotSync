from __future__ import annotations

import argparse
import asyncio
import base64
import ipaddress
import json
import logging
import os
import signal
from collections.abc import Sequence
from dataclasses import dataclass, field
from typing import Any

from websockets.asyncio.server import ServerConnection, serve
from websockets.exceptions import ConnectionClosed

from .http import (
    MAX_HTTP_HEADER_BYTES,
    RequestError,
    read_http_head,
    read_http_body,
    write_http_response,
)
from .mls import MLSDeliveryServer, MLSDeliveryStore
from .protocol import PROTOCOL_VERSION, SUPPORTED_VERSIONS

WEBSOCKET_PATH = "/v2/pairing"
DELIVERY_PATH_PREFIX = "/v2/mls/"
DEFAULT_DELIVERY_DATABASE_PATH = "relay-data/mls.sqlite3"
MAX_DELIVERY_REQUEST_BYTES = 1024 * 1024
MAX_REGISTRATION_BYTES = 512
MAX_BINARY_MESSAGE_BYTES = 512 * 1024
MAX_FORWARD_QUEUE_FRAMES = 16
MAX_FORWARD_QUEUE_BYTES = 1024 * 1024
REGISTRATION_TIMEOUT_SECONDS = 5.0
DEFAULT_MAX_CONNECTIONS = 256
DEFAULT_MAX_ROOMS = 128
DEFAULT_MAX_DELIVERY_CONNECTIONS = 64
DEFAULT_MAX_SOCKETS_PER_ROUTE = 2
# Must stay aligned with ProductSyncPolicy.pairingWindowTimeToLive (15 minutes)
# so physical QR + phrase pairing is not cut short by the relay waiting room.
DEFAULT_WAITING_ROOM_TTL_SECONDS = 900.0

PEER_READY = json.dumps(
    {"type": "peerReady", "version": PROTOCOL_VERSION},
    separators=(",", ":"),
    sort_keys=True,
)
PEER_LEFT = json.dumps(
    {"type": "peerLeft", "version": PROTOCOL_VERSION},
    separators=(",", ":"),
    sort_keys=True,
)
ROUTE_FULL = json.dumps(
    {"code": "routeFull", "type": "error", "version": PROTOCOL_VERSION},
    separators=(",", ":"),
    sort_keys=True,
)
RELAY_BUSY = json.dumps(
    {"code": "relayBusy", "type": "error", "version": PROTOCOL_VERSION},
    separators=(",", ":"),
    sort_keys=True,
)
WAITING_EXPIRED = json.dumps(
    {"code": "waitingExpired", "type": "error", "version": PROTOCOL_VERSION},
    separators=(",", ":"),
    sort_keys=True,
)

COUNTER_NAMES = (
    "websocket_connections_opened",
    "websocket_connections_closed",
    "registrations_accepted",
    "registrations_rejected",
    "route_capacity_rejections",
    "connection_capacity_rejections",
    "room_capacity_rejections",
    "waiting_room_expirations",
    "path_rejections",
    "protocol_errors",
    "binary_frames_forwarded",
    "binary_bytes_forwarded",
    "binary_frames_dropped_no_peer",
    "binary_bytes_dropped_no_peer",
    "forward_queue_overflows",
    "control_frames_sent",
    "delivery_requests",
    "delivery_connection_capacity_rejections",
    "delivery_bad_requests",
    "internal_errors",
)


class RegistrationError(ValueError):
    pass


class Metrics:
    def __init__(self) -> None:
        self._counters = dict.fromkeys(COUNTER_NAMES, 0)
        self._active_connections = 0
        self._active_rooms = 0

    def increment(self, name: str, amount: int = 1) -> None:
        if name not in self._counters:
            raise KeyError(name)
        if amount < 0:
            raise ValueError("counter increments must be non-negative")
        self._counters[name] += amount

    def set_active(self, *, connections: int, rooms: int) -> None:
        if connections < 0 or rooms < 0:
            raise ValueError("active gauges must be non-negative")
        self._active_connections = connections
        self._active_rooms = rooms

    def reset_counters(self) -> None:
        for name in self._counters:
            self._counters[name] = 0

    def snapshot(self) -> dict[str, Any]:
        return {
            "counters": dict(self._counters),
            "gauges": {
                "active_connections": self._active_connections,
                "active_rooms": self._active_rooms,
            },
            "version": PROTOCOL_VERSION,
        }


def _unique_json_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise RegistrationError("registration contains duplicate fields")
        result[key] = value
    return result


def parse_registration(message: str | bytes) -> bytes:
    if not isinstance(message, str):
        raise RegistrationError("registration must be a text frame")

    try:
        encoded = message.encode("utf-8")
    except UnicodeEncodeError as error:
        raise RegistrationError("registration is not valid UTF-8") from error

    if len(encoded) > MAX_REGISTRATION_BYTES:
        raise RegistrationError("registration is too large")

    try:
        document = json.loads(message, object_pairs_hook=_unique_json_object)
    except (json.JSONDecodeError, RegistrationError) as error:
        raise RegistrationError("registration is not valid JSON") from error

    if not isinstance(document, dict):
        raise RegistrationError("registration must be an object")
    if set(document) != {"type", "version", "route"}:
        raise RegistrationError("registration has the wrong shape")
    if document["type"] != "register":
        raise RegistrationError("registration has the wrong type")
    if type(document["version"]) is not int or document["version"] != PROTOCOL_VERSION:
        raise RegistrationError("registration has the wrong version")

    route = document["route"]
    if not isinstance(route, str) or len(route) != 43:
        raise RegistrationError("registration has an invalid route")
    try:
        route_ascii = route.encode("ascii")
        decoded = base64.b64decode(route_ascii + b"=", altchars=b"-_", validate=True)
    except (UnicodeEncodeError, ValueError) as error:
        raise RegistrationError("registration has an invalid route") from error
    canonical = base64.urlsafe_b64encode(decoded).rstrip(b"=")
    if len(decoded) != 32 or canonical != route_ascii:
        raise RegistrationError("registration has an invalid route")
    return decoded


@dataclass(frozen=True, slots=True)
class OutboundMessage:
    payload: str | bytes
    byte_count: int
    forwarded_binary: bool


class BoundedOutboundQueue:
    def __init__(
        self,
        frame_limit: int = MAX_FORWARD_QUEUE_FRAMES,
        byte_limit: int = MAX_FORWARD_QUEUE_BYTES,
    ) -> None:
        if frame_limit <= 0 or byte_limit <= 0:
            raise ValueError("queue limits must be positive")
        self._frame_limit = frame_limit
        self._byte_limit = byte_limit
        self._queue: asyncio.Queue[OutboundMessage] = asyncio.Queue(
            maxsize=frame_limit
        )
        self._queued_bytes = 0

    @property
    def frame_count(self) -> int:
        return self._queue.qsize()

    @property
    def byte_count(self) -> int:
        return self._queued_bytes

    def enqueue(self, payload: str | bytes, *, forwarded_binary: bool) -> bool:
        byte_count = (
            len(payload) if isinstance(payload, bytes) else len(payload.encode("utf-8"))
        )
        if self._queue.qsize() >= self._frame_limit:
            return False
        if self._queued_bytes + byte_count > self._byte_limit:
            return False
        self._queue.put_nowait(
            OutboundMessage(
                payload=payload,
                byte_count=byte_count,
                forwarded_binary=forwarded_binary,
            )
        )
        self._queued_bytes += byte_count
        return True

    async def dequeue(self) -> OutboundMessage:
        message = await self._queue.get()
        self._queued_bytes -= message.byte_count
        return message


@dataclass(slots=True, eq=False)
class Member:
    socket: ServerConnection
    route: bytes
    outbound: BoundedOutboundQueue = field(default_factory=BoundedOutboundQueue)
    joined: bool = False


@dataclass(slots=True)
class Room:
    members: list[Member] = field(default_factory=list)
    waiting_expiry: asyncio.Task[None] | None = None


class RelayService:
    def __init__(
        self,
        metrics: Metrics | None = None,
        *,
        max_connections: int = DEFAULT_MAX_CONNECTIONS,
        max_rooms: int = DEFAULT_MAX_ROOMS,
        max_sockets_per_route: int = DEFAULT_MAX_SOCKETS_PER_ROUTE,
        waiting_room_ttl: float = DEFAULT_WAITING_ROOM_TTL_SECONDS,
    ) -> None:
        if max_connections <= 0:
            raise ValueError("max_connections must be positive")
        if max_rooms <= 0:
            raise ValueError("max_rooms must be positive")
        if max_sockets_per_route <= 0:
            raise ValueError("max_sockets_per_route must be positive")
        if waiting_room_ttl <= 0:
            raise ValueError("waiting_room_ttl must be positive")
        self.metrics = metrics or Metrics()
        self.max_connections = max_connections
        self.max_rooms = max_rooms
        self.max_sockets_per_route = max_sockets_per_route
        self.waiting_room_ttl = waiting_room_ttl
        self._rooms: dict[bytes, Room] = {}
        self._connection_count = 0
        self._live_connection_count = 0
        self._expiry_tasks: set[asyncio.Task[None]] = set()
        self._lock = asyncio.Lock()

    @property
    def room_count(self) -> int:
        return len(self._rooms)

    @property
    def connection_count(self) -> int:
        return self._connection_count

    @property
    def live_connection_count(self) -> int:
        return self._live_connection_count

    async def handle(self, socket: ServerConnection) -> None:
        self.metrics.increment("websocket_connections_opened")
        member: Member | None = None
        admitted = False
        try:
            admitted = await self._admit_connection()
            if not admitted:
                self.metrics.increment("connection_capacity_rejections")
                await self._send_and_close(socket, RELAY_BUSY, 1013, "relay busy")
                return

            request = socket.request
            if request is None or request.path != WEBSOCKET_PATH:
                self.metrics.increment("path_rejections")
                await self._close(socket, 1008, "unsupported endpoint")
                return

            try:
                async with asyncio.timeout(REGISTRATION_TIMEOUT_SECONDS):
                    first_message = await socket.recv()
                route = parse_registration(first_message)
            except TimeoutError:
                self.metrics.increment("registrations_rejected")
                await self._close(socket, 1008, "registration timeout")
                return
            except RegistrationError:
                self.metrics.increment("registrations_rejected")
                await self._close(socket, 1008, "invalid registration")
                return
            except ConnectionClosed:
                return

            member = Member(socket=socket, route=route)
            join_result = await self._join(member)
            if join_result == "routeFull":
                self.metrics.increment("route_capacity_rejections")
                await self._send_and_close(socket, ROUTE_FULL, 1008, "route full")
                return
            if join_result == "relayBusy":
                self.metrics.increment("room_capacity_rejections")
                await self._send_and_close(socket, RELAY_BUSY, 1013, "relay busy")
                return

            self.metrics.increment("registrations_accepted")
            await self._run_member(member)
        except ConnectionClosed:
            pass
        except Exception:
            self.metrics.increment("internal_errors")
            await self._close(socket, 1011, "relay error")
        finally:
            if member is not None and member.joined:
                await self._leave(member)
            if admitted:
                await self._release_connection()
            self.metrics.increment("websocket_connections_closed")

    async def _admit_connection(self) -> bool:
        async with self._lock:
            if self._live_connection_count >= self.max_connections:
                return False
            self._live_connection_count += 1
            return True

    async def _release_connection(self) -> None:
        async with self._lock:
            self._live_connection_count -= 1

    async def _join(self, member: Member) -> str:
        async with self._lock:
            room = self._rooms.get(member.route)
            if room is None:
                if len(self._rooms) >= self.max_rooms:
                    return "relayBusy"
                room = Room()
                self._rooms[member.route] = room
            if len(room.members) >= self.max_sockets_per_route:
                return "routeFull"

            room.members.append(member)
            member.joined = True
            self._connection_count += 1
            self._update_active_metrics()

            if len(room.members) == 1:
                self._start_waiting_expiry(member.route, room, member)
            elif len(room.members) >= 2:
                # Multi-member rooms stay open without short lone-peer expiry.
                self._cancel_waiting_expiry(room)
                for peer in room.members:
                    if peer is member:
                        continue
                    if not peer.outbound.enqueue(
                        PEER_READY, forwarded_binary=False
                    ):
                        raise RuntimeError("room control queue is unexpectedly full")
                if not member.outbound.enqueue(
                    PEER_READY, forwarded_binary=False
                ):
                    raise RuntimeError("new member control queue is unexpectedly full")
            return "joined"

    async def _leave(self, member: Member) -> None:
        peers_to_close: list[Member] = []
        async with self._lock:
            room = self._rooms.get(member.route)
            if room is None or member not in room.members:
                member.joined = False
                return

            room.members.remove(member)
            member.joined = False
            self._connection_count -= 1
            if room.members:
                if len(room.members) == 1:
                    # Pairing / lone survivor waiting room.
                    self._start_waiting_expiry(
                        member.route, room, room.members[0]
                    )
                else:
                    self._cancel_waiting_expiry(room)
                for peer in room.members:
                    if not peer.outbound.enqueue(
                        PEER_LEFT, forwarded_binary=False
                    ):
                        self.metrics.increment("forward_queue_overflows")
                        peers_to_close.append(peer)
            else:
                self._cancel_waiting_expiry(room)
                del self._rooms[member.route]
            self._update_active_metrics()

        for peer in peers_to_close:
            await self._close(peer.socket, 1013, "forward queue full")

    def _start_waiting_expiry(
        self,
        route: bytes,
        room: Room,
        member: Member,
    ) -> None:
        self._cancel_waiting_expiry(room)
        task = asyncio.create_task(self._expire_waiting_member(route, room, member))
        room.waiting_expiry = task
        self._expiry_tasks.add(task)
        task.add_done_callback(self._expiry_tasks.discard)

    @staticmethod
    def _cancel_waiting_expiry(room: Room) -> None:
        task = room.waiting_expiry
        room.waiting_expiry = None
        if task is not None and task is not asyncio.current_task():
            task.cancel()

    async def _expire_waiting_member(
        self,
        route: bytes,
        expected_room: Room,
        member: Member,
    ) -> None:
        try:
            await asyncio.sleep(self.waiting_room_ttl)
        except asyncio.CancelledError:
            return

        async with self._lock:
            room = self._rooms.get(route)
            current_task = asyncio.current_task()
            if (
                room is not expected_room
                or room.waiting_expiry is not current_task
                or room.members != [member]
            ):
                return
            room.waiting_expiry = None
            room.members.clear()
            member.joined = False
            del self._rooms[route]
            self._connection_count -= 1
            self.metrics.increment("waiting_room_expirations")
            self._update_active_metrics()

        await self._send_and_close(
            member.socket,
            WAITING_EXPIRED,
            1008,
            "waiting room expired",
        )

    async def _run_member(self, member: Member) -> None:
        reader_task = asyncio.create_task(self._read_messages(member))
        writer_task = asyncio.create_task(self._write_messages(member))
        tasks = {reader_task, writer_task}
        done, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        for task in pending:
            task.cancel()
        results = await asyncio.gather(*done, *pending, return_exceptions=True)
        for result in results:
            if isinstance(result, BaseException) and not isinstance(
                result, (asyncio.CancelledError, ConnectionClosed)
            ):
                raise result

    async def _read_messages(self, member: Member) -> None:
        async for message in member.socket:
            if not isinstance(message, bytes):
                self.metrics.increment("protocol_errors")
                await self._close(member.socket, 1003, "binary frames required")
                return
            await self._forward(member, message)

    async def _write_messages(self, member: Member) -> None:
        while True:
            message = await member.outbound.dequeue()
            await member.socket.send(message.payload)
            if message.forwarded_binary:
                self.metrics.increment("binary_frames_forwarded")
                self.metrics.increment("binary_bytes_forwarded", message.byte_count)
            else:
                self.metrics.increment("control_frames_sent")

    async def _forward(self, sender: Member, payload: bytes) -> None:
        peers_to_close: list[Member] = []
        async with self._lock:
            room = self._rooms.get(sender.route)
            if (
                room is None
                or sender not in room.members
                or len(room.members) < 2
            ):
                self.metrics.increment("binary_frames_dropped_no_peer")
                self.metrics.increment("binary_bytes_dropped_no_peer", len(payload))
                return

            for peer in room.members:
                if peer is sender:
                    continue
                if not peer.outbound.enqueue(payload, forwarded_binary=True):
                    self.metrics.increment("forward_queue_overflows")
                    peers_to_close.append(peer)

        for peer in peers_to_close:
            await self._close(peer.socket, 1013, "forward queue full")

    def _update_active_metrics(self) -> None:
        self.metrics.set_active(
            connections=self.connection_count,
            rooms=self.room_count,
        )

    @staticmethod
    async def _close(socket: ServerConnection, code: int, reason: str) -> None:
        try:
            await socket.close(code=code, reason=reason)
        except ConnectionClosed:
            pass

    @staticmethod
    async def _send_and_close(
        socket: ServerConnection,
        payload: str,
        code: int,
        reason: str,
    ) -> None:
        try:
            await socket.send(payload)
        except ConnectionClosed:
            return
        await RelayService._close(socket, code, reason)


class RelayServer:
    def __init__(
        self,
        *,
        host: str = "127.0.0.1",
        port: int = 8765,
        metrics_host: str = "127.0.0.1",
        metrics_port: int = 8766,
        delivery_host: str = "127.0.0.1",
        delivery_port: int = 8767,
        delivery_database_path: str | os.PathLike[str] = DEFAULT_DELIVERY_DATABASE_PATH,
        delivery_max_connections: int = DEFAULT_MAX_DELIVERY_CONNECTIONS,
        metrics: Metrics | None = None,
        max_connections: int = DEFAULT_MAX_CONNECTIONS,
        max_rooms: int = DEFAULT_MAX_ROOMS,
        waiting_room_ttl: float = DEFAULT_WAITING_ROOM_TTL_SECONDS,
        allow_insecure_non_loopback: bool = False,
    ) -> None:
        _require_loopback(metrics_host, label="metrics host")
        if not allow_insecure_non_loopback:
            _require_loopback(host, label="relay host")
            _require_loopback(delivery_host, label="delivery host")
        if not all(
            0 <= candidate <= 65535
            for candidate in (port, metrics_port, delivery_port)
        ):
            raise ValueError("ports must be between 0 and 65535")
        if delivery_max_connections <= 0:
            raise ValueError("delivery max connections must be positive")
        self.host = host
        self.port = port
        self.metrics_host = metrics_host
        self.metrics_port = metrics_port
        self.delivery_host = delivery_host
        self.delivery_port = delivery_port
        self.delivery_max_connections = delivery_max_connections
        self.service = RelayService(
            metrics,
            max_connections=max_connections,
            max_rooms=max_rooms,
            waiting_room_ttl=waiting_room_ttl,
        )
        self.mls = MLSDeliveryServer(MLSDeliveryStore(delivery_database_path))
        self._websocket_server: Any | None = None
        self._metrics_server: asyncio.Server | None = None
        self._delivery_server: asyncio.Server | None = None
        self._delivery_tasks: set[asyncio.Task[Any]] = set()
        self._websocket_logger = logging.Logger("gotsync-server-websocket")
        self._websocket_logger.addHandler(logging.NullHandler())
        self._websocket_logger.propagate = False
        self._websocket_logger.disabled = True

    @property
    def websocket_port(self) -> int:
        if self._websocket_server is None or not self._websocket_server.sockets:
            raise RuntimeError("relay is not running")
        return int(self._websocket_server.sockets[0].getsockname()[1])

    @property
    def bound_metrics_port(self) -> int:
        if self._metrics_server is None or not self._metrics_server.sockets:
            raise RuntimeError("metrics server is not running")
        return int(self._metrics_server.sockets[0].getsockname()[1])

    @property
    def bound_delivery_port(self) -> int:
        if self._delivery_server is None or not self._delivery_server.sockets:
            raise RuntimeError("delivery server is not running")
        return int(self._delivery_server.sockets[0].getsockname()[1])

    async def start(self) -> None:
        if (
            self._websocket_server is not None
            or self._metrics_server is not None
            or self._delivery_server is not None
        ):
            raise RuntimeError("relay is already running")
        try:
            self._websocket_server = await serve(
                self.service.handle,
                self.host,
                self.port,
                compression=None,
                max_size=MAX_BINARY_MESSAGE_BYTES,
                max_queue=MAX_FORWARD_QUEUE_FRAMES,
                write_limit=64 * 1024,
                ping_interval=20,
                ping_timeout=20,
                close_timeout=5,
                open_timeout=5,
                server_header=None,
                logger=self._websocket_logger,
            )
            self._metrics_server = await asyncio.start_server(
                self._handle_metrics_http,
                self.metrics_host,
                self.metrics_port,
                limit=8192,
            )
            self._delivery_server = await asyncio.start_server(
                self._accept_delivery_http,
                self.delivery_host,
                self.delivery_port,
                limit=MAX_HTTP_HEADER_BYTES,
            )
        except BaseException:
            if self._delivery_server is not None:
                self._delivery_server.close()
                await self._delivery_server.wait_closed()
                self._delivery_server = None
            if self._metrics_server is not None:
                self._metrics_server.close()
                await self._metrics_server.wait_closed()
                self._metrics_server = None
            if self._websocket_server is not None:
                self._websocket_server.close()
                await self._websocket_server.wait_closed()
                self._websocket_server = None
            self.mls.store.close()
            raise

    async def close(self) -> None:
        delivery_server = self._delivery_server
        metrics_server = self._metrics_server
        websocket_server = self._websocket_server
        self._delivery_server = None
        self._metrics_server = None
        self._websocket_server = None

        if delivery_server is not None:
            delivery_server.close()
            await delivery_server.wait_closed()
        current_task = asyncio.current_task()
        delivery_tasks = [
            task for task in self._delivery_tasks if task is not current_task
        ]
        if delivery_tasks:
            await asyncio.gather(*delivery_tasks, return_exceptions=True)
        if metrics_server is not None:
            metrics_server.close()
            await metrics_server.wait_closed()
        if websocket_server is not None:
            websocket_server.close(close_connections=True)
            await websocket_server.wait_closed()
        self.mls.store.close()

    async def __aenter__(self) -> RelayServer:
        await self.start()
        return self

    async def __aexit__(self, *_: object) -> None:
        await self.close()

    def _accept_delivery_http(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
    ) -> None:
        if len(self._delivery_tasks) >= self.delivery_max_connections:
            self.service.metrics.increment(
                "delivery_connection_capacity_rejections"
            )
            writer.close()
            return
        task = asyncio.create_task(self._handle_delivery_http(reader, writer))
        self._delivery_tasks.add(task)
        task.add_done_callback(self._delivery_tasks.discard)

    async def _handle_delivery_http(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> None:
        self.service.metrics.increment("delivery_requests")
        try:
            try:
                method, target, headers = await read_http_head(reader)
                if method != "POST" or not target.startswith(DELIVERY_PATH_PREFIX):
                    await write_http_response(writer, 404, {"error": "notFound", "version": PROTOCOL_VERSION})
                    return
                body = await read_http_body(
                    reader, headers, maximum_body_bytes=MAX_DELIVERY_REQUEST_BYTES,
                )
                await self.mls.handle_request(target, headers, body, writer)
            except RequestError as error:
                self.service.metrics.increment("delivery_bad_requests")
                await write_http_response(
                    writer,
                    error.status,
                    {"error": error.code, "version": PROTOCOL_VERSION},
                )
        except ConnectionError:
            pass
        except Exception:
            self.service.metrics.increment("internal_errors")
            try:
                await write_http_response(
                    writer,
                    500,
                    {"error": "internalError", "version": PROTOCOL_VERSION},
                )
            except ConnectionError:
                pass
        finally:
            writer.close()
            try:
                await writer.wait_closed()
            except ConnectionError:
                pass

    async def _handle_metrics_http(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> None:
        try:
            try:
                raw_request = await asyncio.wait_for(
                    reader.readuntil(b"\r\n\r\n"), timeout=2
                )
            except (TimeoutError, asyncio.IncompleteReadError):
                return
            except asyncio.LimitOverrunError:
                await write_http_response(writer, 431, {"error": "headers too large"})
                return

            try:
                request_line = raw_request.split(b"\r\n", 1)[0].decode("ascii")
                method, target, version = request_line.split(" ")
            except (UnicodeDecodeError, ValueError):
                await write_http_response(writer, 400, {"error": "bad request"})
                return
            if version != "HTTP/1.1":
                await write_http_response(writer, 400, {"error": "bad request"})
                return

            if method == "GET" and target == "/healthz":
                await write_http_response(
                    writer,
                    200,
                    {"status": "ok", "version": PROTOCOL_VERSION, "supportedVersions": SUPPORTED_VERSIONS},
                )
            elif method == "GET" and target == "/readyz":
                try:
                    ready = await asyncio.wait_for(
                        asyncio.to_thread(self.mls.store.is_ready),
                        timeout=1,
                    )
                except TimeoutError:
                    ready = False
                await write_http_response(
                    writer,
                    200 if ready else 503,
                    {
                        "status": "ready" if ready else "unavailable",
                        "version": PROTOCOL_VERSION,
                    },
                )
            elif method == "GET" and target == "/metrics":
                await write_http_response(writer, 200, self.service.metrics.snapshot())
            elif method == "POST" and target == "/metrics/reset":
                self.service.metrics.reset_counters()
                await write_http_response(writer, 200, self.service.metrics.snapshot())
            else:
                await write_http_response(writer, 404, {"error": "not found", "version": PROTOCOL_VERSION})
        except ConnectionError:
            pass
        except Exception:
            self.service.metrics.increment("internal_errors")
        finally:
            writer.close()
            try:
                await writer.wait_closed()
            except ConnectionError:
                pass


def _require_loopback(host: str, *, label: str) -> None:
    if host == "localhost":
        return
    try:
        address = ipaddress.ip_address(host)
    except ValueError as error:
        raise ValueError(f"{label} must be a loopback address") from error
    if not address.is_loopback:
        raise ValueError(f"{label} must be a loopback address")


def _argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="GotSync pairing relay and MLS delivery service"
    )
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", default=8765, type=int)
    parser.add_argument("--metrics-host", default="127.0.0.1")
    parser.add_argument("--metrics-port", default=8766, type=int)
    parser.add_argument("--delivery-host", default="127.0.0.1")
    parser.add_argument("--delivery-port", default=8767, type=int)
    parser.add_argument("--database", default=DEFAULT_DELIVERY_DATABASE_PATH)
    parser.add_argument(
        "--delivery-max-connections",
        default=DEFAULT_MAX_DELIVERY_CONNECTIONS,
        type=int,
    )
    parser.add_argument(
        "--allow-insecure-non-loopback",
        action="store_true",
        help="allow plaintext relay listeners on non-loopback interfaces",
    )
    parser.add_argument("--max-connections", default=DEFAULT_MAX_CONNECTIONS, type=int)
    parser.add_argument("--max-rooms", default=DEFAULT_MAX_ROOMS, type=int)
    parser.add_argument(
        "--waiting-room-ttl",
        default=DEFAULT_WAITING_ROOM_TTL_SECONDS,
        type=float,
    )
    return parser


async def _run_until_stopped(args: argparse.Namespace) -> None:
    relay = RelayServer(
        host=args.host,
        port=args.port,
        metrics_host=args.metrics_host,
        metrics_port=args.metrics_port,
        delivery_host=args.delivery_host,
        delivery_port=args.delivery_port,
        delivery_database_path=args.database,
        delivery_max_connections=args.delivery_max_connections,
        max_connections=args.max_connections,
        max_rooms=args.max_rooms,
        waiting_room_ttl=args.waiting_room_ttl,
        allow_insecure_non_loopback=args.allow_insecure_non_loopback,
    )
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    installed_signals: list[signal.Signals] = []

    for stop_signal in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(stop_signal, stop.set)
            installed_signals.append(stop_signal)
        except NotImplementedError:
            pass

    try:
        if args.allow_insecure_non_loopback:
            logging.warning(
                "plaintext relay listeners may be reachable beyond this machine"
            )
        await relay.start()
        print(f"pairing relay ready on {relay.host}:{relay.websocket_port}{WEBSOCKET_PATH}")
        print(
            "health and aggregate metrics ready on "
            f"{relay.metrics_host}:{relay.bound_metrics_port}"
        )
        print(
            "MLS delivery ready on "
            f"{relay.delivery_host}:{relay.bound_delivery_port}/v2/mls"
        )
        await stop.wait()
    finally:
        await relay.close()
        for stop_signal in installed_signals:
            loop.remove_signal_handler(stop_signal)


def main(argv: Sequence[str] | None = None) -> int:
    args = _argument_parser().parse_args(argv)
    try:
        asyncio.run(_run_until_stopped(args))
    except KeyboardInterrupt:
        pass
    return 0
