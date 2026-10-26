from __future__ import annotations

import hashlib
import hmac
import ipaddress
import math
import time
from collections import OrderedDict
from collections.abc import Callable, Iterable, Mapping
from dataclasses import dataclass, field
from pathlib import Path

IPNetwork = ipaddress.IPv4Network | ipaddress.IPv6Network
IPAddress = ipaddress.IPv4Address | ipaddress.IPv6Address

ADMISSION_HEADER = "x-gotsync-admission"
DEFAULT_CLIENT_IP_HEADER = "x-forwarded-for"
DEFAULT_MAX_TRACKED_SOURCES = 65_536
DEFAULT_IPV6_SOURCE_PREFIX = 64
DEFAULT_WEBSOCKET_CONNECT_RATE = 2.0
DEFAULT_WEBSOCKET_CONNECT_BURST = 30
DEFAULT_MAX_WEBSOCKETS_PER_SOURCE = 32
DEFAULT_HTTP_REQUEST_RATE = 40.0
DEFAULT_HTTP_REQUEST_BURST = 400
DEFAULT_MAX_HTTP_REQUESTS_PER_SOURCE = 16
MINIMUM_ADMISSION_TOKEN_LENGTH = 32
UNKNOWN_SOURCE = "unknown"


@dataclass(frozen=True, slots=True)
class RateLimit:
    rate: float
    burst: int

    def __post_init__(self) -> None:
        if not math.isfinite(self.rate) or self.rate < 0:
            raise ValueError("rate must be finite and non-negative")
        if type(self.burst) is not int or self.burst < 0:
            raise ValueError("burst must be a non-negative integer")
        if (self.rate == 0) != (self.burst == 0):
            raise ValueError("rate and burst must both be zero to disable a limit")

    @property
    def enabled(self) -> bool:
        return self.rate > 0


class TokenBucketLimiter:
    def __init__(
        self,
        limit: RateLimit,
        *,
        max_sources: int = DEFAULT_MAX_TRACKED_SOURCES,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        if max_sources <= 0:
            raise ValueError("max_sources must be positive")
        self.limit = limit
        self.max_sources = max_sources
        self._clock = clock
        self._buckets: OrderedDict[str, tuple[float, float]] = OrderedDict()

    @property
    def tracked_sources(self) -> int:
        return len(self._buckets)

    def acquire(self, source: str) -> float | None:
        """Take one token for `source`, or return the seconds until one is available."""
        if not self.limit.enabled:
            return None
        now = self._clock()
        tokens, updated = self._buckets.get(source, (float(self.limit.burst), now))
        tokens = min(float(self.limit.burst), tokens + (now - updated) * self.limit.rate)
        if tokens < 1:
            self._buckets[source] = (tokens, now)
            self._buckets.move_to_end(source)
            return (1 - tokens) / self.limit.rate
        tokens -= 1
        if source not in self._buckets and len(self._buckets) >= self.max_sources:
            self._buckets.popitem(last=False)
        self._buckets[source] = (tokens, now)
        self._buckets.move_to_end(source)
        return None


class ConcurrencyLimiter:
    def __init__(self, limit: int) -> None:
        if type(limit) is not int or limit < 0:
            raise ValueError("concurrency limit must be a non-negative integer")
        self.limit = limit
        self._active: dict[str, int] = {}

    @property
    def tracked_sources(self) -> int:
        return len(self._active)

    def acquire(self, source: str) -> bool:
        active = self._active.get(source, 0)
        if self.limit and active >= self.limit:
            return False
        self._active[source] = active + 1
        return True

    def release(self, source: str) -> None:
        active = self._active.get(source, 0) - 1
        if active > 0:
            self._active[source] = active
        else:
            self._active.pop(source, None)


@dataclass(frozen=True, slots=True)
class AdmissionConfig:
    trusted_proxies: tuple[IPNetwork, ...] = ()
    client_ip_header: str = DEFAULT_CLIENT_IP_HEADER
    ipv6_source_prefix: int = DEFAULT_IPV6_SOURCE_PREFIX
    max_tracked_sources: int = DEFAULT_MAX_TRACKED_SOURCES
    websocket_connects: RateLimit = RateLimit(
        DEFAULT_WEBSOCKET_CONNECT_RATE, DEFAULT_WEBSOCKET_CONNECT_BURST
    )
    max_websockets_per_source: int = DEFAULT_MAX_WEBSOCKETS_PER_SOURCE
    http_requests: RateLimit = RateLimit(
        DEFAULT_HTTP_REQUEST_RATE, DEFAULT_HTTP_REQUEST_BURST
    )
    max_http_requests_per_source: int = DEFAULT_MAX_HTTP_REQUESTS_PER_SOURCE
    allowed_networks: tuple[IPNetwork, ...] = ()
    admission_token_digests: frozenset[bytes] = field(default_factory=frozenset)

    def __post_init__(self) -> None:
        if not 1 <= self.ipv6_source_prefix <= 128:
            raise ValueError("ipv6_source_prefix must be between 1 and 128")
        if self.max_tracked_sources <= 0:
            raise ValueError("max_tracked_sources must be positive")
        if self.max_websockets_per_source < 0 or self.max_http_requests_per_source < 0:
            raise ValueError("per-source concurrency limits must be non-negative")
        name = self.client_ip_header.strip().lower()
        if not name or any(character.isspace() or character == ":" for character in name):
            raise ValueError("client_ip_header must be a header name")
        object.__setattr__(self, "client_ip_header", name)

    @staticmethod
    def token_digest(token: str) -> bytes:
        return hashlib.sha256(token.encode("utf-8")).digest()

    @classmethod
    def with_tokens(cls, tokens: Iterable[str], **options: object) -> AdmissionConfig:
        digests: set[bytes] = set()
        for token in tokens:
            if len(token) < MINIMUM_ADMISSION_TOKEN_LENGTH or not token.isascii() or not token.isprintable() or " " in token:
                raise ValueError(
                    f"admission tokens must be at least {MINIMUM_ADMISSION_TOKEN_LENGTH} "
                    "printable ASCII characters without spaces"
                )
            digests.add(cls.token_digest(token))
        return cls(admission_token_digests=frozenset(digests), **options)  # type: ignore[arg-type]

    @property
    def requires_admission(self) -> bool:
        return bool(self.allowed_networks or self.admission_token_digests)


def read_admission_tokens(path: str | Path) -> list[str]:
    tokens = []
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        token = line.strip()
        if token and not token.startswith("#"):
            tokens.append(token)
    if not tokens:
        raise ValueError("admission token file contains no tokens")
    return tokens


def parse_network(value: str) -> IPNetwork:
    return ipaddress.ip_network(value.strip(), strict=False)


def _parse_address(value: str) -> IPAddress | None:
    candidate = value.strip()
    if candidate.startswith("[") and "]" in candidate:
        candidate = candidate[1:candidate.index("]")]
    elif candidate.count(":") == 1 and "." in candidate:
        candidate = candidate.split(":", 1)[0]
    try:
        address = ipaddress.ip_address(candidate)
    except ValueError:
        return None
    if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped is not None:
        return address.ipv4_mapped
    return address


@dataclass(frozen=True, slots=True)
class ClientSource:
    address: IPAddress | None
    key: str


@dataclass(frozen=True, slots=True)
class Rejection:
    code: str
    status: int
    retry_after: int | None = None


class AdmissionController:
    def __init__(
        self,
        config: AdmissionConfig | None = None,
        *,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.config = config or AdmissionConfig()
        self.websocket_connects = TokenBucketLimiter(
            self.config.websocket_connects,
            max_sources=self.config.max_tracked_sources,
            clock=clock,
        )
        self.http_requests = TokenBucketLimiter(
            self.config.http_requests,
            max_sources=self.config.max_tracked_sources,
            clock=clock,
        )
        self.websockets = ConcurrencyLimiter(self.config.max_websockets_per_source)
        self.http_in_flight = ConcurrencyLimiter(self.config.max_http_requests_per_source)

    def is_trusted_proxy(self, address: IPAddress | None) -> bool:
        return address is not None and any(
            address in network for network in self.config.trusted_proxies
        )

    def resolve_source(
        self,
        peer: object,
        headers: Mapping[str, str] | None,
    ) -> ClientSource:
        peer_address = _parse_address(peer[0]) if isinstance(peer, tuple) and peer and isinstance(peer[0], str) else None
        address = peer_address
        if self.is_trusted_proxy(peer_address) and headers is not None:
            forwarded = headers.get(self.config.client_ip_header)
            if forwarded:
                for hop in reversed(forwarded.split(",")):
                    hop_address = _parse_address(hop)
                    if hop_address is None:
                        break
                    address = hop_address
                    if not self.is_trusted_proxy(hop_address):
                        break
        return ClientSource(address=address, key=self._source_key(address))

    def _source_key(self, address: IPAddress | None) -> str:
        if address is None:
            return UNKNOWN_SOURCE
        if isinstance(address, ipaddress.IPv6Address):
            network = ipaddress.IPv6Network(
                (address, self.config.ipv6_source_prefix), strict=False
            )
            return str(network)
        return str(address)

    def admit(self, source: ClientSource, headers: Mapping[str, str] | None) -> Rejection | None:
        config = self.config
        if config.allowed_networks and (
            source.address is None
            or not any(source.address in network for network in config.allowed_networks)
        ):
            return Rejection("admissionDenied", 403)
        if config.admission_token_digests:
            presented = (headers or {}).get(ADMISSION_HEADER, "")
            digest = AdmissionConfig.token_digest(presented)
            matched = False
            for candidate in config.admission_token_digests:
                matched |= hmac.compare_digest(digest, candidate)
            if not presented or not matched:
                return Rejection("admissionDenied", 403)
        return None

    @staticmethod
    def rate_limited(retry_after: float) -> Rejection:
        return Rejection(
            "rateLimited",
            429,
            max(1, math.ceil(retry_after)),
        )
