from __future__ import annotations

import argparse
import asyncio
import base64
import ipaddress
import json
import logging
import math
import os
import signal
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from websockets.asyncio.server import ServerConnection, serve
from websockets.exceptions import ConnectionClosed

from .mailbox import (
    DEFAULT_MAILBOX_RETENTION_SECONDS,
    DEFAULT_MAILBOX_PURGE_INTERVAL_SECONDS,
    DEFAULT_MAX_GLOBAL_LIVE_BYTES,
    DEFAULT_MAX_GLOBAL_RECEIPTS,
    DEFAULT_MAX_ROUTE_LIVE_BYTES,
    DEFAULT_MAX_ROUTE_RECEIPTS,
    MAX_MAILBOX_BATCH_MESSAGES,
    MAX_MAILBOX_PAYLOAD_BYTES,
    MAX_MAILBOX_REQUEST_BYTES,
    MAX_MAILBOX_RESPONSE_BYTES,
    MailboxAuthorizationError,
    MailboxCapacityError,
    MailboxConflictError,
    MailboxError,
    MailboxHeadersTooLargeError,
    MailboxPutMessage,
    MailboxRequestTooLargeError,
    MailboxStore,
    authorize_mailbox,
    decode_canonical_base64url,
    encode_base64url,
)

from .protocol import PROTOCOL_VERSION, SUPPORTED_VERSIONS
WEBSOCKET_PATH = "/v1"
DEFAULT_MAILBOX_DATABASE_PATH = "relay-data/mailbox.sqlite3"
MAX_HTTP_HEADER_BYTES = 8192
MAX_REGISTRATION_BYTES = 512
MAX_BINARY_MESSAGE_BYTES = 512 * 1024
MAX_FORWARD_QUEUE_FRAMES = 16
MAX_FORWARD_QUEUE_BYTES = 1024 * 1024
REGISTRATION_TIMEOUT_SECONDS = 5.0
DEFAULT_MAX_CONNECTIONS = 256
DEFAULT_MAX_ROOMS = 128
DEFAULT_MAX_MAILBOX_CONNECTIONS = 64
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
    "mailbox_requests",
    "mailbox_connection_capacity_rejections",
    "mailbox_bad_requests",
    "mailbox_authorization_rejections",
    "mailbox_capacity_rejections",
    "mailbox_conflicts",
    "mailbox_messages_put",
    "mailbox_messages_fetched",
    "mailbox_messages_acked",
    "mailbox_routes_forgotten",
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
        mailbox_host: str = "127.0.0.1",
        mailbox_port: int = 8767,
        mailbox_database_path: str | os.PathLike[str] = DEFAULT_MAILBOX_DATABASE_PATH,
        mailbox_retention_seconds: float = DEFAULT_MAILBOX_RETENTION_SECONDS,
        mailbox_purge_interval_seconds: float = (
            DEFAULT_MAILBOX_PURGE_INTERVAL_SECONDS
        ),
        mailbox_max_route_receipts: int = DEFAULT_MAX_ROUTE_RECEIPTS,
        mailbox_max_route_live_bytes: int = DEFAULT_MAX_ROUTE_LIVE_BYTES,
        mailbox_max_global_receipts: int = DEFAULT_MAX_GLOBAL_RECEIPTS,
        mailbox_max_global_live_bytes: int = DEFAULT_MAX_GLOBAL_LIVE_BYTES,
        mailbox_max_connections: int = DEFAULT_MAX_MAILBOX_CONNECTIONS,
        metrics: Metrics | None = None,
        max_connections: int = DEFAULT_MAX_CONNECTIONS,
        max_rooms: int = DEFAULT_MAX_ROOMS,
        waiting_room_ttl: float = DEFAULT_WAITING_ROOM_TTL_SECONDS,
        mailbox_clock: Callable[[], float] | None = None,
        allow_insecure_non_loopback: bool = False,
    ) -> None:
        _require_loopback(metrics_host, label="metrics host")
        if not allow_insecure_non_loopback:
            _require_loopback(host, label="relay host")
            _require_loopback(mailbox_host, label="mailbox host")
        if (
            not math.isfinite(mailbox_purge_interval_seconds)
            or mailbox_purge_interval_seconds <= 0
        ):
            raise ValueError(
                "mailbox_purge_interval_seconds must be finite and positive"
            )
        if not all(
            0 <= candidate <= 65535
            for candidate in (port, metrics_port, mailbox_port)
        ):
            raise ValueError("ports must be between 0 and 65535")
        if mailbox_max_connections <= 0:
            raise ValueError("mailbox max connections must be positive")
        self.host = host
        self.port = port
        self.metrics_host = metrics_host
        self.metrics_port = metrics_port
        self.mailbox_host = mailbox_host
        self.mailbox_port = mailbox_port
        self.mailbox_purge_interval_seconds = mailbox_purge_interval_seconds
        self.mailbox_max_connections = mailbox_max_connections
        self.service = RelayService(
            metrics,
            max_connections=max_connections,
            max_rooms=max_rooms,
            waiting_room_ttl=waiting_room_ttl,
        )
        mailbox_options: dict[str, Any] = {
            "retention_seconds": mailbox_retention_seconds,
            "max_route_receipts": mailbox_max_route_receipts,
            "max_route_live_bytes": mailbox_max_route_live_bytes,
            "max_global_receipts": mailbox_max_global_receipts,
            "max_global_live_bytes": mailbox_max_global_live_bytes,
        }
        if mailbox_clock is not None:
            mailbox_options["clock"] = mailbox_clock
        self.mailbox = MailboxStore(mailbox_database_path, **mailbox_options)
        from .mls import MLSDeliveryServer, MLSDeliveryStore
        self.mls = MLSDeliveryServer(MLSDeliveryStore(Path(mailbox_database_path).with_name("mls.sqlite3")))
        self._websocket_server: Any | None = None
        self._metrics_server: asyncio.Server | None = None
        self._mailbox_server: asyncio.Server | None = None
        self._mailbox_tasks: set[asyncio.Task[Any]] = set()
        self._mailbox_purge_task: asyncio.Task[None] | None = None
        self._mailbox_purge_stop = asyncio.Event()
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
    def bound_mailbox_port(self) -> int:
        if self._mailbox_server is None or not self._mailbox_server.sockets:
            raise RuntimeError("mailbox server is not running")
        return int(self._mailbox_server.sockets[0].getsockname()[1])

    async def start(self) -> None:
        if (
            self._websocket_server is not None
            or self._metrics_server is not None
            or self._mailbox_server is not None
            or self._mailbox_purge_task is not None
        ):
            raise RuntimeError("relay is already running")
        try:
            await asyncio.to_thread(self.mailbox.purge_expired)
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
            self._mailbox_server = await asyncio.start_server(
                self._accept_mailbox_http,
                self.mailbox_host,
                self.mailbox_port,
                limit=MAX_HTTP_HEADER_BYTES,
            )
            self._mailbox_purge_task = asyncio.create_task(
                self._purge_mailbox_periodically()
            )
        except BaseException:
            if self._mailbox_purge_task is not None:
                self._mailbox_purge_stop.set()
                await self._mailbox_purge_task
                self._mailbox_purge_task = None
            if self._mailbox_server is not None:
                self._mailbox_server.close()
                await self._mailbox_server.wait_closed()
                self._mailbox_server = None
            if self._metrics_server is not None:
                self._metrics_server.close()
                await self._metrics_server.wait_closed()
                self._metrics_server = None
            if self._websocket_server is not None:
                self._websocket_server.close()
                await self._websocket_server.wait_closed()
                self._websocket_server = None
            self.mailbox.close()
            self.mls.store.close()
            raise

    async def close(self) -> None:
        mailbox_purge_task = self._mailbox_purge_task
        mailbox_server = self._mailbox_server
        metrics_server = self._metrics_server
        websocket_server = self._websocket_server
        self._mailbox_purge_task = None
        self._mailbox_server = None
        self._metrics_server = None
        self._websocket_server = None

        if mailbox_purge_task is not None:
            self._mailbox_purge_stop.set()
            await mailbox_purge_task
        if mailbox_server is not None:
            mailbox_server.close()
            await mailbox_server.wait_closed()
        current_task = asyncio.current_task()
        mailbox_tasks = [
            task for task in self._mailbox_tasks if task is not current_task
        ]
        if mailbox_tasks:
            await asyncio.gather(*mailbox_tasks, return_exceptions=True)
        if metrics_server is not None:
            metrics_server.close()
            await metrics_server.wait_closed()
        if websocket_server is not None:
            websocket_server.close(close_connections=True)
            await websocket_server.wait_closed()
        self.mailbox.close()
        self.mls.store.close()

    async def __aenter__(self) -> RelayServer:
        await self.start()
        return self

    async def __aexit__(self, *_: object) -> None:
        await self.close()

    def _accept_mailbox_http(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
    ) -> None:
        if len(self._mailbox_tasks) >= self.mailbox_max_connections:
            self.service.metrics.increment(
                "mailbox_connection_capacity_rejections"
            )
            writer.close()
            return
        task = asyncio.create_task(self._handle_mailbox_http(reader, writer))
        self._mailbox_tasks.add(task)
        task.add_done_callback(self._mailbox_tasks.discard)

    async def _purge_mailbox_periodically(self) -> None:
        while not self._mailbox_purge_stop.is_set():
            try:
                await asyncio.wait_for(
                    self._mailbox_purge_stop.wait(),
                    timeout=self.mailbox_purge_interval_seconds,
                )
                return
            except TimeoutError:
                pass
            try:
                await asyncio.to_thread(self.mailbox.purge_expired)
            except Exception:
                self.service.metrics.increment("internal_errors")

    async def _handle_mailbox_http(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> None:
        self.service.metrics.increment("mailbox_requests")
        try:
            try:
                method, target, headers, body = await read_http_json_request(
                    reader,
                    maximum_body_bytes=lambda path: 1024 * 1024 if path.startswith("/v2/mls/") else MAX_MAILBOX_REQUEST_BYTES,
                )
                if method == "POST" and target.startswith("/v2/mls/"):
                    await self.mls.handle_request(target, headers, body, writer)
                    return
                if method != "POST":
                    await write_http_response(writer, 404, {"error": "notFound", "version": PROTOCOL_VERSION})
                    return
                if headers.get("content-type", "").split(";", 1)[0].strip().lower() != (
                    "application/json"
                ):
                    raise MailboxError("content type must be application/json")
                document = parse_mailbox_json(body)
                _require_mailbox_version(document)

                if target == "/v1/mailbox/put":
                    response = await self._mailbox_put(document)
                elif target == "/v1/mailbox/fetch":
                    response = await self._mailbox_fetch(document)
                elif target == "/v1/mailbox/ack":
                    response = await self._mailbox_ack(document)
                elif target == "/v1/mailbox/forget":
                    response = await self._mailbox_forget(document)
                else:
                    await write_http_response(writer, 404, {"error": "notFound", "version": PROTOCOL_VERSION})
                    return
                await write_http_response(writer, 200, response)
            except MailboxAuthorizationError as error:
                self.service.metrics.increment("mailbox_authorization_rejections")
                await write_http_response(
                    writer,
                    error.status,
                    {"error": error.code, "version": PROTOCOL_VERSION},
                )
            except MailboxConflictError as error:
                self.service.metrics.increment("mailbox_conflicts")
                await write_http_response(
                    writer,
                    error.status,
                    {"error": error.code, "version": PROTOCOL_VERSION},
                )
            except MailboxCapacityError as error:
                self.service.metrics.increment("mailbox_capacity_rejections")
                await write_http_response(
                    writer,
                    error.status,
                    {"error": error.code, "version": PROTOCOL_VERSION},
                )
            except MailboxError as error:
                self.service.metrics.increment("mailbox_bad_requests")
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

    async def _mailbox_put(self, document: dict[str, Any]) -> dict[str, Any]:
        _require_fields(document, required={"route", "auth", "messages"}, optional={"version"})
        route, _ = _mailbox_credentials(document)
        raw_messages = document["messages"]
        if not isinstance(raw_messages, list):
            raise MailboxError("messages must be an array")
        if not 1 <= len(raw_messages) <= MAX_MAILBOX_BATCH_MESSAGES:
            raise MailboxError("messages batch has the wrong size")

        messages: list[MailboxPutMessage] = []
        seen_ids: set[bytes] = set()
        for raw_message in raw_messages:
            if not isinstance(raw_message, dict):
                raise MailboxError("message must be an object")
            _require_fields(raw_message, required={"id", "payload"})
            message_id = decode_canonical_base64url(
                raw_message["id"],
                field="id",
                exact_bytes=32,
            )
            if message_id in seen_ids:
                raise MailboxError("messages contains duplicate ids")
            seen_ids.add(message_id)
            payload = decode_canonical_base64url(
                raw_message["payload"],
                field="payload",
                maximum_bytes=MAX_MAILBOX_PAYLOAD_BYTES,
            )
            messages.append(MailboxPutMessage(message_id, payload))

        stored = await asyncio.to_thread(self.mailbox.put, route, messages)
        self.service.metrics.increment("mailbox_messages_put", len(messages))
        return {
            "messages": [
                {
                    "acknowledged": message.acknowledged,
                    "cursor": message.cursor,
                    "id": encode_base64url(message.message_id),
                }
                for message in stored
            ],
            "version": PROTOCOL_VERSION,
        }

    async def _mailbox_fetch(self, document: dict[str, Any]) -> dict[str, Any]:
        _require_fields(
            document,
            required={"route", "auth", "after"},
            optional={"limit", "version"},
        )
        route, _ = _mailbox_credentials(document)
        after = _require_cursor(document["after"], field="after")
        limit = document.get("limit", MAX_MAILBOX_BATCH_MESSAGES)
        if type(limit) is not int or not 1 <= limit <= MAX_MAILBOX_BATCH_MESSAGES:
            raise MailboxError("limit is out of range")

        page = await asyncio.to_thread(
            self.mailbox.fetch,
            route,
            after_cursor=after,
            limit=limit,
        )
        message_documents = [
            {
                "cursor": message.cursor,
                "id": encode_base64url(message.message_id),
                "payload": encode_base64url(message.payload),
            }
            for message in page.messages
        ]

        def response_for(message_count: int) -> dict[str, Any]:
            selected = message_documents[:message_count]
            next_cursor = selected[-1]["cursor"] if selected else after
            return {
                "hasMore": page.has_more or message_count < len(message_documents),
                "messages": selected,
                "nextCursor": next_cursor,
                "version": PROTOCOL_VERSION,
            }

        response = response_for(len(message_documents))
        if len(_encode_json_document(response)) > MAX_MAILBOX_RESPONSE_BYTES:
            lower_bound = 1
            upper_bound = len(message_documents) - 1
            selected_count = 0
            while lower_bound <= upper_bound:
                candidate_count = (lower_bound + upper_bound) // 2
                candidate = response_for(candidate_count)
                if (
                    len(_encode_json_document(candidate))
                    <= MAX_MAILBOX_RESPONSE_BYTES
                ):
                    selected_count = candidate_count
                    lower_bound = candidate_count + 1
                else:
                    upper_bound = candidate_count - 1
            if selected_count == 0:
                raise RuntimeError("one mailbox envelope exceeds response limit")
            response = response_for(selected_count)

        self.service.metrics.increment(
            "mailbox_messages_fetched",
            len(response["messages"]),
        )
        return response

    async def _mailbox_ack(self, document: dict[str, Any]) -> dict[str, Any]:
        _require_fields(document, required={"route", "auth", "cursor"}, optional={"version"})
        route, _ = _mailbox_credentials(document)
        cursor = _require_cursor(document["cursor"], field="cursor")
        acknowledged = await asyncio.to_thread(
            self.mailbox.acknowledge,
            route,
            through_cursor=cursor,
        )
        self.service.metrics.increment("mailbox_messages_acked", acknowledged)
        return {
            "acked": acknowledged,
            "cursor": cursor,
            "version": PROTOCOL_VERSION,
        }

    async def _mailbox_forget(self, document: dict[str, Any]) -> dict[str, Any]:
        _require_fields(document, required={"route", "auth"}, optional={"version"})
        route, _ = _mailbox_credentials(document)
        deleted = await asyncio.to_thread(self.mailbox.forget, route)
        if deleted:
            self.service.metrics.increment("mailbox_routes_forgotten")
        return {"forgotten": True, "version": PROTOCOL_VERSION}

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
                        asyncio.to_thread(self.mailbox.is_ready),
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


async def read_http_json_request(
    reader: asyncio.StreamReader,
    *,
    maximum_body_bytes: int | Callable[[str], int],
) -> tuple[str, str, dict[str, str], bytes]:
    try:
        raw_headers = await asyncio.wait_for(
            reader.readuntil(b"\r\n\r\n"),
            timeout=2,
        )
    except TimeoutError as error:
        raise MailboxError("request timed out") from error
    except asyncio.IncompleteReadError as error:
        raise MailboxError("incomplete request") from error
    except asyncio.LimitOverrunError as error:
        raise MailboxHeadersTooLargeError("headers are too large") from error
    if len(raw_headers) > MAX_HTTP_HEADER_BYTES:
        raise MailboxHeadersTooLargeError("headers are too large")

    lines = raw_headers[:-4].split(b"\r\n")
    try:
        request_line = lines[0].decode("ascii")
        method, target, version = request_line.split(" ")
    except (UnicodeDecodeError, ValueError) as error:
        raise MailboxError("invalid request line") from error
    if version != "HTTP/1.1" or not target.startswith("/"):
        raise MailboxError("invalid request line")
    if "?" in target or "#" in target:
        raise MailboxError("mailbox endpoint cannot contain a query")

    headers: dict[str, str] = {}
    valid_header_name_bytes = frozenset(
        b"!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
    )
    for raw_line in lines[1:]:
        if b":" not in raw_line:
            raise MailboxError("invalid header")
        raw_name, raw_value = raw_line.split(b":", 1)
        if not raw_name or any(
            byte not in valid_header_name_bytes for byte in raw_name
        ):
            raise MailboxError("invalid header")
        try:
            name = raw_name.decode("ascii").lower()
            value = raw_value.decode("ascii").strip()
        except UnicodeDecodeError as error:
            raise MailboxError("invalid header") from error
        if name in headers:
            raise MailboxError("duplicate or invalid header")
        headers[name] = value

    if "transfer-encoding" in headers:
        raise MailboxError("transfer encoding is unsupported")
    raw_content_length = headers.get("content-length")
    if raw_content_length is None or not raw_content_length.isdigit():
        raise MailboxError("valid content length is required")
    if len(raw_content_length) > 10:
        raise MailboxRequestTooLargeError("request body is too large")
    content_length = int(raw_content_length)
    body_limit = maximum_body_bytes(target) if callable(maximum_body_bytes) else maximum_body_bytes
    if content_length > body_limit:
        raise MailboxRequestTooLargeError("request body is too large")
    try:
        body = await asyncio.wait_for(
            reader.readexactly(content_length),
            timeout=2,
        )
    except TimeoutError as error:
        raise MailboxError("request body timed out") from error
    except asyncio.IncompleteReadError as error:
        raise MailboxError("incomplete request body") from error
    return method, target, headers, body


def parse_mailbox_json(body: bytes) -> dict[str, Any]:
    def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise MailboxError("JSON contains duplicate fields")
            result[key] = value
        return result

    try:
        document = json.loads(
            body.decode("utf-8"),
            object_pairs_hook=unique_object,
        )
    except (
        UnicodeDecodeError,
        json.JSONDecodeError,
        RecursionError,
        ValueError,
    ) as error:
        raise MailboxError("request body is not valid JSON") from error
    if not isinstance(document, dict):
        raise MailboxError("request body must be an object")
    return document


class MailboxVersionError(MailboxError):
    code = "unsupportedVersion"


def _require_mailbox_version(document: dict[str, Any]) -> None:
    version = document.get("version", PROTOCOL_VERSION)
    if type(version) is not int or version != PROTOCOL_VERSION:
        raise MailboxVersionError("unsupported mailbox protocol version")


def _require_fields(
    document: dict[str, Any],
    *,
    required: set[str],
    optional: set[str] | None = None,
) -> None:
    allowed = required | (optional or set())
    if not required.issubset(document) or not set(document).issubset(allowed):
        raise MailboxError("request has the wrong shape")


def _mailbox_credentials(document: dict[str, Any]) -> tuple[bytes, bytes]:
    route = decode_canonical_base64url(
        document["route"],
        field="route",
        exact_bytes=32,
    )
    auth = decode_canonical_base64url(
        document["auth"],
        field="auth",
        exact_bytes=32,
    )
    authorize_mailbox(route, auth)
    return route, auth


def _require_cursor(value: object, *, field: str) -> int:
    if type(value) is not int or not 0 <= value <= 2**63 - 1:
        raise MailboxError(f"{field} cursor is out of range")
    return value


def _require_loopback(host: str, *, label: str) -> None:
    if host == "localhost":
        return
    try:
        address = ipaddress.ip_address(host)
    except ValueError as error:
        raise ValueError(f"{label} must be a loopback address") from error
    if not address.is_loopback:
        raise ValueError(f"{label} must be a loopback address")


async def write_http_response(
    writer: asyncio.StreamWriter, status: int, document: dict[str, Any]
) -> None:
    reasons = {
        200: "OK",
        400: "Bad Request",
        401: "Unauthorized",
        403: "Forbidden",
        404: "Not Found",
        409: "Conflict",
        413: "Content Too Large",
        429: "Too Many Requests",
        431: "Request Header Fields Too Large",
        500: "Internal Server Error",
        503: "Service Unavailable",
    }
    body = _encode_json_document(document)
    headers = (
        f"HTTP/1.1 {status} {reasons[status]}\r\n"
        "Content-Type: application/json\r\n"
        f"Content-Length: {len(body)}\r\n"
        "Cache-Control: no-store\r\n"
        "Connection: close\r\n"
        "\r\n"
    ).encode("ascii")
    writer.write(headers + body)
    try:
        await writer.drain()
    except ConnectionError:
        pass


def _encode_json_document(document: dict[str, Any]) -> bytes:
    return json.dumps(
        document,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def _argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="GotSync live relay and encrypted mailbox"
    )
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", default=8765, type=int)
    parser.add_argument("--metrics-host", default="127.0.0.1")
    parser.add_argument("--metrics-port", default=8766, type=int)
    parser.add_argument("--mailbox-host", default="127.0.0.1")
    parser.add_argument("--mailbox-port", default=8767, type=int)
    parser.add_argument(
        "--mailbox-database",
        default=DEFAULT_MAILBOX_DATABASE_PATH,
    )
    parser.add_argument(
        "--mailbox-retention",
        default=DEFAULT_MAILBOX_RETENTION_SECONDS,
        type=float,
        help="encrypted mailbox retention in seconds",
    )
    parser.add_argument(
        "--mailbox-purge-interval",
        default=DEFAULT_MAILBOX_PURGE_INTERVAL_SECONDS,
        type=float,
        help="expired mailbox purge interval in seconds",
    )
    parser.add_argument(
        "--mailbox-max-route-receipts",
        default=DEFAULT_MAX_ROUTE_RECEIPTS,
        type=int,
    )
    parser.add_argument(
        "--mailbox-max-route-live-bytes",
        default=DEFAULT_MAX_ROUTE_LIVE_BYTES,
        type=int,
    )
    parser.add_argument(
        "--mailbox-max-global-receipts",
        default=DEFAULT_MAX_GLOBAL_RECEIPTS,
        type=int,
    )
    parser.add_argument(
        "--mailbox-max-global-live-bytes",
        default=DEFAULT_MAX_GLOBAL_LIVE_BYTES,
        type=int,
    )
    parser.add_argument(
        "--mailbox-max-connections",
        default=DEFAULT_MAX_MAILBOX_CONNECTIONS,
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
        mailbox_host=args.mailbox_host,
        mailbox_port=args.mailbox_port,
        mailbox_database_path=args.mailbox_database,
        mailbox_retention_seconds=args.mailbox_retention,
        mailbox_purge_interval_seconds=args.mailbox_purge_interval,
        mailbox_max_route_receipts=args.mailbox_max_route_receipts,
        mailbox_max_route_live_bytes=args.mailbox_max_route_live_bytes,
        mailbox_max_global_receipts=args.mailbox_max_global_receipts,
        mailbox_max_global_live_bytes=args.mailbox_max_global_live_bytes,
        mailbox_max_connections=args.mailbox_max_connections,
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
        print(f"relay ready on {relay.host}:{relay.websocket_port}/v1")
        print(
            "health and aggregate metrics ready on "
            f"{relay.metrics_host}:{relay.bound_metrics_port}"
        )
        print(
            "encrypted mailbox ready on "
            f"{relay.mailbox_host}:{relay.bound_mailbox_port}"
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
