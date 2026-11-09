"""Control-isolation benchmark for the optional relay blob lane.

Synthetic standard-library HTTP clients drive the real MLS delivery and blob HTTP APIs with opaque random bytes.
There is no MLS cryptography, no AES-GCM, no descriptor and no Swift or app client.
"""
from __future__ import annotations

import argparse
import base64
import contextlib
import hashlib
import http.client
import ipaddress
import json
import math
import os
import platform
import random
import shutil
import signal
import socket
import sqlite3
import ssl
import subprocess
import sys
import tempfile
import threading
import time
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

CYCLES = 200
CYCLE_SECONDS = 0.1
RECOVERY_SECONDS = 15
WARMUP_SECONDS = 20
TAIL_SECONDS = 10
WRITERS = 10
POOL_LENGTHS = ("two", "two", "one", "one")
FRESH_PER_WRITER = 6
UPLOAD_INTERVAL_SECONDS = 1.5
GET_INTERVAL_SECONDS = 4.0
APPLICATION_BYTES = 1024
REQUEST_TIMEOUT = 30
RETRY_STATUSES = (0, 429, 503, 507)
P95_DELTA_SECONDS = 0.25
P99_DELTA_SECONDS = 1.0
MIN_TRANSFERS_PER_SECOND = 1.0
RUN_SECONDS = {"direct": 240, "traefik": 300}
RESERVED_WINDOWS = {"l3a2b-direct-1": ("direct", 15 * 60), "l3a2b-traefik-1": ("traefik", 25 * 60)}
HEAVY_JOBS = frozenset({"xcodebuild", "xctest", "swift-test", "swiftpm-xctest-helper"})
TEST_NETWORK = ipaddress.ip_network("198.51.100.0/24")
DIRECTORY_PREFIX = "gotsync-blob-bench-"


def b64(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode()


# Destination and window guards


def check_destination(mode: str, via: str, host: str) -> None:
    try:
        address = ipaddress.ip_address(via)
    except ValueError:
        address = None
    if mode == "direct":
        allowed = address is not None and address.is_loopback and host == "localhost"
    elif mode == "traefik":
        allowed = address is not None and address in TEST_NETWORK and host.endswith(".test")
    else:
        allowed = False
    if not allowed:
        raise ValueError(f"refusing {via} ({host}) for {mode} mode: only loopback or the owned test network")


def parse_time(value: str) -> float:
    from datetime import datetime

    return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def preflight(mode: str, window: str, assigned: list[dict[str, str]], processes: list[tuple[int, int, str]],
              now: float, own_group: int) -> list[str]:
    """Reasons this slot cannot be used. Nothing is stopped or waited for."""
    reasons = []
    if RESERVED_WINDOWS.get(window, ("",))[0] != mode:
        reasons.append(f"{window!r} is not the reserved {mode} window")
    own = [entry for entry in assigned if entry["id"] == window]
    if len(own) != 1:
        reasons.append(f"{window!r} has no single assigned slot")
    elif not parse_time(own[0]["start"]) <= now < parse_time(own[0]["end"]):
        reasons.append(f"now is outside the assigned slot of {window!r}")
    for entry in assigned:
        if entry["id"] != window and parse_time(entry["start"]) <= now < parse_time(entry["end"]):
            reasons.append(f"assigned window {entry['id']!r} is active")
    for pid, group, command in processes:
        if group == own_group or not command:
            continue
        name = os.path.basename(command.split()[0])
        if name in HEAVY_JOBS or "bench-blob-isolation" in command:
            reasons.append(f"coordinated job running: pid {pid} {name}")
    return reasons


def own_slot_end(window: str, assigned: list[dict[str, str]]) -> float:
    return min(parse_time(entry["end"]) for entry in assigned if entry["id"] == window)


def host_processes() -> list[tuple[int, int, str]]:
    output = subprocess.run(["ps", "-axo", "pid=,pgid=,command="], capture_output=True, text=True, check=True).stdout
    processes = []
    for line in output.splitlines():
        fields = line.split(None, 2)
        if len(fields) >= 2:
            processes.append((int(fields[0]), int(fields[1]), fields[2] if len(fields) == 3 else ""))
    return processes


def host_load() -> dict[str, Any]:
    load = os.getloadavg()
    return {"loadAverage": [round(value, 2) for value in load], "cpus": os.cpu_count(), "memoryBytes": memory_bytes()}


def memory_bytes() -> int | None:
    with contextlib.suppress(OSError, ValueError, subprocess.SubprocessError):
        if sys.platform == "darwin":
            return int(subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True).stdout)
        return os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES")
    return None


# Owned cleanup


class OwnedProcess:
    """A child started in its own process group; only that group is ever signalled."""

    def __init__(self, arguments: list[str], **options: Any) -> None:
        self.process = subprocess.Popen(arguments, start_new_session=True, **options)
        self.group = self.process.pid

    def signal(self, number: int) -> None:
        with contextlib.suppress(ProcessLookupError, PermissionError):
            os.killpg(self.group, number)

    def stop(self, grace: float = 10) -> int:
        if self.process.poll() is None:
            self.signal(signal.SIGTERM)
        try:
            self.process.wait(grace)
        except subprocess.TimeoutExpired:
            self.signal(signal.SIGKILL)
            self.process.wait()
        self.signal(signal.SIGKILL)
        return self.process.returncode


def owned_directory() -> Path:
    return Path(tempfile.mkdtemp(prefix=DIRECTORY_PREFIX))


def remove_owned_directory(path: Path, created: Path) -> None:
    if path != created or not path.name.startswith(DIRECTORY_PREFIX):
        raise ValueError(f"refusing to remove {path}: not the directory this run created")
    shutil.rmtree(path)


def docker_leftovers(project: str, run: Callable[..., Any] = subprocess.run) -> list[str]:
    leftovers = []
    for kind in ("container", "network", "volume"):
        for label in (f"com.docker.compose.project={project}", f"gotsync.bench={project}"):
            command = ["docker", kind, "ls", "-q", "--filter", f"label={label}"]
            if kind == "container":
                command.insert(3, "-a")
            output = run(command, capture_output=True, text=True, check=True).stdout.split()
            leftovers += [f"{kind} {name}" for name in output]
    return sorted(set(leftovers))


# Evaluation


def percentile(samples: list[float], q: float) -> float:
    ordered = sorted(samples)
    return ordered[max(0, math.ceil(q / 100 * len(ordered)) - 1)]


def summarize_phase(phase: dict[str, Any]) -> dict[str, Any]:
    latencies = [sample[2] for sample in phase["samples"]]
    statuses = Counter(str(sample[1]) for sample in phase["samples"])
    by_operation = {}
    for operation in sorted({sample[0] for sample in phase["samples"]}):
        values = [sample[2] for sample in phase["samples"] if sample[0] == operation]
        by_operation[operation] = {"p50": percentile(values, 50), "p95": percentile(values, 95),
                                   "p99": percentile(values, 99)}
    return {
        "requests": len(latencies), "statuses": dict(statuses),
        "p50": percentile(latencies, 50), "p95": percentile(latencies, 95), "p99": percentile(latencies, 99),
        "operations": by_operation, "seconds": phase["seconds"],
        "requestsPerSecond": len(latencies) / phase["seconds"] if phase["seconds"] else None,
    }


def sustained(times: list[float], start: float, end: float) -> tuple[float, int]:
    inside = [value for value in times if start <= value <= end]
    quarter = (end - start) / 4
    empty = sum(1 for index in range(4)
                if not any(start + index * quarter <= value <= start + (index + 1) * quarter for value in inside))
    return len(inside) / (end - start), empty


def evaluate(run: dict[str, Any]) -> dict[str, Any]:
    """Pass, fail or invalid for one run: fail on any threshold, invalid when the run is not evidence."""
    fail, invalid = [], []
    phases = {}
    for name in ("unloaded", "loaded"):
        phase = run[name]
        if len(phase["samples"]) != 3 * CYCLES:
            invalid.append(f"{name}: {len(phase['samples'])} control samples instead of {3 * CYCLES}")
        if not phase["samples"]:
            return {"verdict": "invalid", "fail": fail, "invalid": invalid, "phases": phases}
        phases[name] = summary = summarize_phase(phase)
        refused = sum(count for status, count in summary["statuses"].items() if status in ("429", "503"))
        if refused:
            fail.append(f"{name}: {refused} control 429/503")
        other = {status: count for status, count in summary["statuses"].items() if status not in ("200", "429", "503")}
        if other:
            fail.append(f"{name}: unexpected control statuses {other}")
        for operation in ("remove", "add", "leave"):
            outcome = phase["membership"].get(operation, {})
            if outcome.get("status") != 200:
                fail.append(f"{name}: {operation} ended with {outcome.get('status')}")
        writers = phase["membership"].get("writers", {})
        if writers.get("active") != writers.get("expectedActive") or writers.get("inactive") != writers.get(
                "expectedInactive"):
            fail.append(f"{name}: writer membership {writers}")
    unloaded, loaded = phases["unloaded"], phases["loaded"]
    if loaded["p95"] > unloaded["p95"] + P95_DELTA_SECONDS:
        fail.append(f"p95 delta {loaded['p95'] - unloaded['p95']:.3f} s exceeds {P95_DELTA_SECONDS} s")
    if loaded["p99"] > unloaded["p99"] + P99_DELTA_SECONDS:
        fail.append(f"p99 delta {loaded['p99'] - unloaded['p99']:.3f} s exceeds {P99_DELTA_SECONDS} s")
    blob = run["blob"]
    for name in ("put", "get"):
        rate, empty = sustained(blob[f"{name}Times"], blob["windowStart"], blob["windowEnd"])
        if rate < MIN_TRANSFERS_PER_SECOND or empty:
            invalid.append(f"blob {name}: {rate:.2f}/s with {empty} empty quarters in the loaded phase")
    if blob.get("mismatches"):
        invalid.append(f"blob get returned {blob['mismatches']} mismatched parts")
    if run.get("overran"):
        invalid.append("the run exceeded its time bound")
    verdict = "fail" if fail else "invalid" if invalid else "pass"
    return {"verdict": verdict, "fail": fail, "invalid": invalid, "phases": phases,
            "deltas": {"p95": loaded["p95"] - unloaded["p95"], "p99": loaded["p99"] - unloaded["p99"]}}


def overall(evaluations: list[dict[str, Any]]) -> str:
    verdicts = {evaluation["verdict"] for evaluation in evaluations}
    return "fail" if "fail" in verdicts else "invalid" if verdicts != {"pass"} else "pass"


# HTTP clients


@dataclass
class Response:
    status: int
    headers: dict[str, str]
    data: bytes
    seconds: float

    def json(self) -> dict[str, Any]:
        try:
            return json.loads(self.data)
        except ValueError:
            return {}

    def retry_after(self) -> float:
        try:
            return max(1.0, float(self.headers.get("retry-after", "1")))
        except ValueError:
            return 1.0


class Client:
    def __init__(self, mode: str, via: str, port: int, host: str, ca_file: str) -> None:
        check_destination(mode, via, host)
        self.via, self.port, self.host = via, port, host
        self.context = ssl.create_default_context(cafile=ca_file)

    def request(self, path: str, body: bytes = b"", token: bytes | None = None,
                content_type: str | None = "application/json") -> Response:
        lines = [f"POST {path} HTTP/1.1", f"Host: {self.host}", "Connection: close", f"Content-Length: {len(body)}"]
        if content_type is not None:
            lines.append(f"Content-Type: {content_type}")
        if token is not None:
            lines.append(f"Authorization: Bearer {b64(token)}")
        start = time.perf_counter()
        try:
            raw = socket.create_connection((self.via, self.port), timeout=REQUEST_TIMEOUT)
            with self.context.wrap_socket(raw, server_hostname=self.host) as sock:
                sock.sendall(("\r\n".join(lines) + "\r\n\r\n").encode() + body)
                response = http.client.HTTPResponse(sock)
                response.begin()
                data = response.read()
                headers = {name.lower(): value for name, value in response.getheaders()}
                return Response(response.status, headers, data, time.perf_counter() - start)
        except (OSError, http.client.HTTPException):
            return Response(0, {}, b"", time.perf_counter() - start)

    def mls(self, operation: str, token: bytes, **values: Any) -> Response:
        return self.request(f"/v2/mls/{operation}", json.dumps({"version": 2, **values}).encode(), token)

    def blob(self, operation: str, token: bytes, **values: Any) -> Response:
        return self.request(f"/v2/mls/blob/{operation}", json.dumps({"version": 2, **values}).encode(), token)

    def part(self, operation: str, token: bytes, group: bytes, object_: bytes, index: int,
             body: bytes = b"") -> Response:
        return self.request(f"/v2/mls/blob/{operation}/{b64(group)}/{b64(object_)}/{index}", body, token,
                            "application/octet-stream" if operation == "put" else None)


# Workload


@dataclass
class BlobObject:
    id: bytes
    length: int
    parts: list[bytes]
    hashes: list[bytes]


def synthetic_object(group: bytes, length: int) -> BlobObject:
    from gotsync_server.blob_format import PART_BYTES, layout, object_id

    count, last = layout(length)
    parts = [os.urandom(PART_BYTES) for _ in range(count - 1)] + [os.urandom(last)]
    hashes = [hashlib.sha256(part).digest() for part in parts]
    return BlobObject(object_id(group, length, tuple(hashes)), length, parts, hashes)


def object_lengths() -> dict[str, int]:
    from gotsync_server.blob_format import PART_BYTES, TAG_BYTES, layout

    lengths = {"one": TAG_BYTES + 1, "two": PART_BYTES + TAG_BYTES + 1}
    assert layout(lengths["one"]).parts == 1 and layout(lengths["two"]).parts == 2
    return lengths


@dataclass(eq=False)
class Writer:
    name: str
    token: bytes = field(default_factory=lambda: os.urandom(32))
    stop: threading.Event = field(default_factory=threading.Event)
    pool: list[BlobObject] = field(default_factory=list)
    fresh_left: int = FRESH_PER_WRITER
    threads: list[threading.Thread] = field(default_factory=list)
    next_upload: float = 0.0

    @property
    def digest(self) -> bytes:
        return hashlib.sha256(self.token).digest()


@dataclass(eq=False)
class Group:
    route: bytes
    writers: list[Writer]
    epoch: int = 0
    head: int = 0
    cursor: int = 0

    @property
    def owner(self) -> Writer:
        return self.writers[0]


def refusal(response: Response) -> str:
    """The relay's error code, or `proxy` for a non-JSON refusal (Traefik)."""
    if response.status in (0, 200):
        return ""
    code = response.json().get("error")
    return f" {code}" if code else " proxy"


def require(response: Response, message: str) -> Response:
    if response.status != 200:
        raise RuntimeError(f"{message}: {response.status} {response.data[:200]!r}")
    return response


def add_writer(client: Client, group: Group, joining: Writer) -> Response:
    reference = require(client.mls("key-package/publish", joining.token, payload=b64(os.urandom(64)),
                                   pairingHash=b64(os.urandom(32))), "publish a key package").json()["reference"]
    response = client.mls("append", group.owner.token, group=b64(group.route), epoch=group.epoch, kind="commit",
                          payload=b64(os.urandom(64)), reference=reference, welcome=b64(os.urandom(64)),
                          addWriter=b64(joining.digest))
    if response.status == 200:
        group.epoch += 1
        group.head = response.json()["entry"]["cursor"]
    return response


def setup_group(client: Client) -> Group:
    group = Group(os.urandom(32), [Writer("A")] + [Writer(f"B{index}") for index in range(1, WRITERS)])
    require(client.mls("create", group.owner.token, group=b64(group.route)), "create a group")
    for writer in group.writers[1:]:
        require(add_writer(client, group, writer), f"add {writer.name}")
    return group


def jittered(seconds: float) -> float:
    return seconds * random.uniform(0.5, 1.5)


def with_retries(stop: threading.Event, deadline: float, call: Callable[[], Response],
                 record: Callable[[Response], None]) -> Response:
    """Retries refusals after Retry-After. Status 0 is retried too: the relay may refuse a part before reading its
    body, and the reset can arrive before its response."""
    while True:
        response = call()
        record(response)
        if response.status not in RETRY_STATUSES or stop.is_set() or time.monotonic() > deadline:
            return response
        stop.wait(response.retry_after())


class BlobLoad:
    def __init__(self, client: Client, group: Group, deadline: float) -> None:
        self.client, self.group, self.deadline = client, group, deadline
        self.lock = threading.Lock()
        self.statuses: Counter[str] = Counter()
        self.after_transition: Counter[str] = Counter()
        self.put_times: list[float] = []
        self.get_times: list[float] = []
        self.bytes_up = self.bytes_down = self.mismatches = self.fresh_objects = 0
        self.events: list[tuple[float, str, str]] = []
        self.transfers: list[tuple[float, str, int]] = []
        self.fresh_open = False
        self.pool: list[BlobObject] = []

    def record(self, writer: Writer, operation: str) -> Callable[[Response], None]:
        def record(response: Response) -> None:
            with self.lock:
                if writer.stop.is_set() and response.status == 403:
                    self.after_transition[f"{writer.name} {operation}"] += 1
                    key = "afterTransition 403"
                else:
                    key = f"{response.status}{refusal(response)}"
                    self.statuses[f"{operation} {key}"] += 1
                self.events.append((time.monotonic(), operation, key))
        return record

    def paced(self, writer: Writer, call: Callable[[], Response]) -> Callable[[], Response]:
        """Starts about one upload request per writer every UPLOAD_INTERVAL_SECONDS, jittered so writers do not
        fire together, without catch-up. With the paced GETs, ten writers offer about 9 requests/s against the
        8/s per-source blob budget."""
        def request() -> Response:
            writer.stop.wait(max(0.0, writer.next_upload - time.monotonic()))
            writer.next_upload = time.monotonic() + jittered(UPLOAD_INTERVAL_SECONDS)
            return call()
        return request

    def upload(self, writer: Writer, item: BlobObject, fresh: bool) -> bool:
        """Begins the object and PUTs the parts the relay reports missing: all of a fresh object, normally none
        of a reused pool object."""
        group = self.group.route
        begin = with_retries(writer.stop, self.deadline, self.paced(writer, lambda: self.client.blob(
            "begin", writer.token, group=b64(group), object=b64(item.id), length=item.length,
            parts=[b64(value) for value in item.hashes])), self.record(writer, "begin"))
        if begin.status != 200:
            return False
        present = set(begin.json().get("present", []))
        for index in range(len(item.parts)):
            if index in present:
                continue
            response = with_retries(writer.stop, self.deadline, self.paced(writer, lambda index=index: self.client.part(
                "put", writer.token, group, item.id, index, item.parts[index])), self.record(writer, "put"))
            if response.status != 200:
                return False
            with self.lock:
                self.put_times.append(time.monotonic())
                self.bytes_up += len(item.parts[index])
                self.transfers.append((self.put_times[-1], "put", len(item.parts[index])))
        if fresh:
            with self.lock:
                self.fresh_objects += 1
        return True

    def prepare(self, writer: Writer, lengths: dict[str, int]) -> None:
        writer.next_upload = time.monotonic() + jittered(UPLOAD_INTERVAL_SECONDS)
        writer.pool = [synthetic_object(self.group.route, lengths[kind]) for kind in POOL_LENGTHS]
        for item in writer.pool:
            if not self.upload(writer, item, fresh=False):
                raise RuntimeError(f"{writer.name} could not upload its pool")
        with self.lock:
            self.pool += writer.pool

    def upload_loop(self, writer: Writer, lengths: dict[str, int]) -> None:
        """Resumes an unfinished fresh object before starting another, as a client would."""
        turn, pending = 0, None
        while not writer.stop.is_set():
            if pending is not None:
                item, fresh = pending, True
            elif self.fresh_open and writer.fresh_left > 0:
                writer.fresh_left -= 1
                item, fresh = synthetic_object(self.group.route, lengths["two"]), True
            else:
                item, fresh = writer.pool[turn % len(writer.pool)], False
                turn += 1
            uploaded = self.upload(writer, item, fresh)
            pending = item if fresh and not uploaded else None
            if not uploaded:
                writer.stop.wait(1)

    def download_loop(self, writer: Writer) -> None:
        """One GET every GET_INTERVAL_SECONDS per writer, without catch-up."""
        next_start = time.monotonic() + jittered(GET_INTERVAL_SECONDS)
        while not writer.stop.wait(max(0.0, next_start - time.monotonic())):
            next_start = time.monotonic() + jittered(GET_INTERVAL_SECONDS)
            item = random.choice(self.pool)
            index = random.randrange(len(item.parts))
            response = with_retries(writer.stop, self.deadline, lambda item=item, index=index: self.client.part(
                "get", writer.token, self.group.route, item.id, index), self.record(writer, "get"))
            if response.status == 200:
                with self.lock:
                    self.get_times.append(time.monotonic())
                    self.bytes_down += len(response.data)
                    self.transfers.append((self.get_times[-1], "get", len(response.data)))
                    self.mismatches += response.data != item.parts[index]

    def start(self, writer: Writer, lengths: dict[str, int]) -> None:
        writer.next_upload = time.monotonic() + jittered(UPLOAD_INTERVAL_SECONDS)
        writer.threads = [threading.Thread(target=self.upload_loop, args=(writer, lengths), daemon=True),
                          threading.Thread(target=self.download_loop, args=(writer,), daemon=True)]
        for thread in writer.threads:
            thread.start()

    def halt(self, writers: list[Writer]) -> None:
        for writer in writers:
            writer.stop.set()

    def stop(self, writers: list[Writer]) -> None:
        self.halt(writers)
        for writer in writers:
            for thread in writer.threads:
                thread.join(REQUEST_TIMEOUT + 5)

    def window(self, start: float, end: float) -> dict[str, Any]:
        """Aggregate blob traffic of all writers inside the loaded measured phase, metadata included."""
        seconds = end - start
        events = [event for event in self.events if start <= event[0] <= end]
        transfers = [transfer for transfer in self.transfers if start <= transfer[0] <= end]
        operations: dict[str, dict[str, Any]] = {}
        for _, operation, key in events:
            counts = operations.setdefault(operation, {"offered": 0, "accepted": 0, "statuses": Counter()})
            counts["offered"] += 1
            counts["accepted"] += key == "200"
            counts["statuses"][key] += 1
        for counts in operations.values():
            counts["statuses"] = dict(counts["statuses"])
        return {
            "seconds": seconds,
            "offeredPerSecond": len(events) / seconds,
            "acceptedPerSecond": sum(1 for event in events if event[2] == "200") / seconds,
            "resets": sum(1 for event in events if event[2] == "0"),
            "operations": operations,
            "putBytes": sum(size for _, kind, size in transfers if kind == "put"),
            "getBytes": sum(size for _, kind, size in transfers if kind == "get"),
        }

    def snapshot(self, start: float, end: float) -> dict[str, Any]:
        return {"window": self.window(start, end),
                "statuses": dict(self.statuses), "afterTransition": dict(self.after_transition),
                "putTimes": self.put_times, "getTimes": self.get_times, "windowStart": start, "windowEnd": end,
                "bytesUp": self.bytes_up, "bytesDown": self.bytes_down, "mismatches": self.mismatches,
                "freshObjects": self.fresh_objects, "poolObjects": len(self.pool)}


def refresh_head(client: Client, group: Group, samples: list | None = None) -> None:
    while True:
        response = client.mls("fetch", group.owner.token, group=b64(group.route), after=group.cursor, limit=32)
        if samples is not None:
            samples.append(("fetch", response.status, response.seconds))
        entries = response.json().get("entries") or []
        if entries:
            group.cursor = entries[-1]["cursor"]
            group.head = max(group.head, group.cursor)
        if samples is not None or not entries:
            return


def remove_writer(client: Client, group: Group, target: Writer, attempts: int = 3) -> dict[str, Any]:
    statuses, start = [], time.perf_counter()
    for _ in range(attempts):
        response = client.mls("append-if-head", group.owner.token, group=b64(group.route), epoch=group.epoch,
                              kind="commit", payload=b64(os.urandom(64)), removeWriter=b64(target.digest),
                              expectedHead=group.head)
        statuses.append(response.status)
        if response.status == 200:
            group.epoch += 1
            group.head = response.json()["entry"]["cursor"]
            break
        if response.json().get("error") != "headAdvanced":
            break
        refresh_head(client, group)
    return {"status": statuses[-1], "attempts": statuses, "seconds": time.perf_counter() - start}


def timed(call: Callable[[], Response]) -> dict[str, Any]:
    response = call()
    return {"status": response.status, "seconds": response.seconds}


def control_workload(client: Client, group: Group, deadline: float, load: BlobLoad | None = None,
                     lengths: dict[str, int] | None = None) -> dict[str, Any]:
    samples: list[tuple[str, int, float]] = []
    owner = group.owner
    start = next_start = time.monotonic()
    for _ in range(CYCLES):
        if time.monotonic() > deadline:
            break
        delay = next_start - time.monotonic()
        if delay > 0:
            time.sleep(delay)
        cycle = time.monotonic()
        refresh_head(client, group, samples)
        response = client.mls("append", owner.token, group=b64(group.route), epoch=group.epoch, kind="application",
                              payload=b64(os.urandom(APPLICATION_BYTES)))
        samples.append(("append", response.status, response.seconds))
        if response.status == 200:
            group.head = response.json()["entry"]["cursor"]
        response = client.mls("ack", owner.token, route=b64(group.route), cursor=group.cursor)
        samples.append(("ack", response.status, response.seconds))
        next_start = cycle + CYCLE_SECONDS
    seconds = time.monotonic() - start

    removed, joining, leaving = group.writers[-1], Writer("E"), group.writers[-2]
    membership: dict[str, Any] = {}
    if load is not None:
        load.halt([removed])
    refresh_head(client, group)
    membership["remove"] = remove_writer(client, group, removed)
    membership["add"] = timed(lambda: add_writer(client, group, joining))
    if load is not None and membership["add"]["status"] == 200:
        joining.pool, joining.fresh_left, removed.fresh_left = removed.pool, removed.fresh_left, 0
        load.start(joining, lengths)
    if load is not None:
        load.halt([leaving])
    membership["leave"] = timed(lambda: client.mls("append", leaving.token, group=b64(group.route),
                                                   epoch=group.epoch, kind="proposal",
                                                   payload=b64(os.urandom(64))))
    group.writers.append(joining)
    return {"samples": samples, "seconds": seconds, "membership": membership,
            "inactive": [removed, leaving]}


def verify_writers(client: Client, group: Group, inactive: list[Writer]) -> dict[str, Any]:
    statuses = {}
    for writer in group.writers:
        for _ in range(10):
            response = client.blob("wanted", writer.token, group=b64(group.route))
            if response.status not in RETRY_STATUSES:
                break
            time.sleep(response.retry_after())
        statuses[writer.name] = response.status
    return {
        "statuses": statuses,
        "active": sorted(name for name, status in statuses.items() if status == 200),
        "inactive": sorted(name for name, status in statuses.items() if status == 403),
        "expectedActive": sorted(writer.name for writer in group.writers if writer not in inactive),
        "expectedInactive": sorted(writer.name for writer in inactive),
    }


def run_once(client: Client, mode: str, extra_groups: int = 0) -> dict[str, Any]:
    started = time.monotonic()
    deadline = started + RUN_SECONDS[mode]
    lengths = object_lengths()
    unloaded_group, loaded_group = setup_group(client), setup_group(client)
    loads = [BlobLoad(client, group, deadline) for group in [loaded_group] + [setup_group(client)
                                                                             for _ in range(extra_groups)]]
    try:
        return measured_run(client, unloaded_group, loaded_group, loads, lengths, started, deadline)
    finally:
        for load in loads:
            load.stop(load.group.writers)


def measured_run(client: Client, unloaded_group: Group, loaded_group: Group, loads: list[BlobLoad],
                 lengths: dict[str, int], started: float, deadline: float) -> dict[str, Any]:
    errors: list[BaseException] = []

    def prepare(load: BlobLoad, writer: Writer) -> None:
        try:
            load.prepare(writer, lengths)
        except BaseException as error:
            errors.append(error)

    preparers = [threading.Thread(target=prepare, args=(load, writer))
                 for load in loads for writer in load.group.writers]
    for thread in preparers:
        thread.start()
    for thread in preparers:
        thread.join()
    if errors:
        raise errors[0]
    setup_seconds = time.monotonic() - started

    time.sleep(RECOVERY_SECONDS)
    unloaded = control_workload(client, unloaded_group, deadline)
    unloaded["membership"]["writers"] = verify_writers(client, unloaded_group, unloaded.pop("inactive"))

    for load in loads:
        for writer in load.group.writers:
            load.start(writer, lengths)
    time.sleep(WARMUP_SECONDS)
    for load in loads:
        load.fresh_open = True
    window_start = time.monotonic()
    loaded = control_workload(client, loaded_group, deadline, loads[0], lengths)
    window_end = time.monotonic()
    for load in loads:
        load.fresh_open = False
    time.sleep(TAIL_SECONDS)
    for load in loads:
        load.stop(load.group.writers)
    loaded["membership"]["writers"] = verify_writers(client, loaded_group, loaded.pop("inactive"))
    return {
        "setupSeconds": setup_seconds, "unloaded": unloaded, "loaded": loaded,
        "blob": loads[0].snapshot(window_start, window_end),
        "otherGroups": [load.snapshot(window_start, window_end) for load in loads[1:]],
        "phaseTimes": {"loadedStart": time.time() - (time.monotonic() - window_start),
                       "loadedEnd": time.time() - (time.monotonic() - window_end)},
        "seconds": time.monotonic() - started, "overran": time.monotonic() > deadline,
    }


# Resource sampling and reports


class ProcessSampler:
    def __init__(self, pid: int, path: Path) -> None:
        self.pid, self.path = pid, path
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.loop, daemon=True)
        self.thread.start()

    def loop(self) -> None:
        with self.path.open("a") as output:
            while not self.stop.wait(1):
                result = subprocess.run(["ps", "-o", "rss=,%cpu=", "-p", str(self.pid)], capture_output=True,
                                        text=True)
                fields = result.stdout.split()
                if len(fields) == 2:
                    output.write(json.dumps({"t": time.time(), "name": "relay", "cpu": float(fields[1]),
                                             "memBytes": int(fields[0]) * 1024}) + "\n")
                    output.flush()

    def close(self) -> None:
        self.stop.set()
        self.thread.join()


def parse_size(value: str) -> int:
    units = {"B": 1, "KiB": 1024, "MiB": 1024**2, "GiB": 1024**3, "kB": 1000, "MB": 1000**2, "GB": 1000**3}
    for unit in sorted(units, key=len, reverse=True):
        if value.endswith(unit):
            return int(float(value[: -len(unit)]) * units[unit])
    return int(float(value))


def read_samples(path: Path) -> list[dict[str, Any]]:
    samples = []
    if path.exists():
        for line in path.read_text().splitlines():
            with contextlib.suppress(ValueError, KeyError):
                record = json.loads(line)
                if "MemUsage" in record:
                    record = {"t": record["t"], "name": record["Name"], "cpu": float(record["CPUPerc"].rstrip("%")),
                              "memBytes": parse_size(record["MemUsage"].split("/")[0].strip())}
                samples.append(record)
    return samples


def resource_summary(samples: list[dict[str, Any]], start: float, end: float) -> dict[str, Any]:
    summary = {}
    for name in sorted({sample["name"] for sample in samples}):
        inside = [sample for sample in samples if sample["name"] == name and start <= sample["t"] <= end]
        if inside:
            summary[name] = {"meanCpuPercent": sum(sample["cpu"] for sample in inside) / len(inside),
                             "peakMemBytes": max(sample["memBytes"] for sample in inside), "samples": len(inside)}
    return summary


def host_info() -> dict[str, Any]:
    return {"os": platform.platform(), "machine": platform.machine(), "python": platform.python_version(),
            "sqlite": sqlite3.sqlite_version, **host_load()}


def markdown(report: dict[str, Any]) -> str:
    lines = [f"# Blob isolation benchmark: {report['window']} ({report['mode']})", "",
             f"Verdict: **{report['verdict']}**. Source `{report.get('revision', 'unknown')}`.", "",
             "Synthetic HTTP clients with opaque random bytes; no MLS cryptography, AES-GCM, Swift or app client.",
             "Blob load is aggregate pressure on one source's shared 8 requests/s budget with sustained transfers; "
             "it is not per-writer saturation or a maximum-throughput result.",
             "", "| Run | Verdict | Unloaded p95/p99 (ms) | Loaded p95/p99 (ms) | Control rps | Blob offered/accepted rps "
             "| PUT/GET ok/s | PUT/GET MB | Resets |",
             "| --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
    for index, run in enumerate(report["runs"], 1):
        evaluation = run["evaluation"]
        phases = evaluation.get("phases", {})
        if "loaded" not in phases:
            lines.append(f"| {index} | {evaluation['verdict']} | | | | | | | |")
            continue
        unloaded, loaded = phases["unloaded"], phases["loaded"]
        window = run["blob"]["window"]
        operations = window["operations"]
        lines.append(
            f"| {index}{' (sensitivity)' if run.get('sensitivity') else ''} | {evaluation['verdict']} "
            f"| {unloaded['p95'] * 1000:.1f}/{unloaded['p99'] * 1000:.1f} "
            f"| {loaded['p95'] * 1000:.1f}/{loaded['p99'] * 1000:.1f} "
            f"| {unloaded['requestsPerSecond']:.1f}/{loaded['requestsPerSecond']:.1f} "
            f"| {window['offeredPerSecond']:.1f}/{window['acceptedPerSecond']:.1f} "
            f"| {operations.get('put', {}).get('accepted', 0) / window['seconds']:.2f}"
            f"/{operations.get('get', {}).get('accepted', 0) / window['seconds']:.2f} "
            f"| {window['putBytes'] / 1e6:.1f}/{window['getBytes'] / 1e6:.1f} | {window['resets']} |")
    lines.append("")
    for index, run in enumerate(report["runs"], 1):
        evaluation = run["evaluation"]
        for reason in evaluation["fail"] + evaluation["invalid"]:
            lines.append(f"- Run {index}: {reason}")
    for key in ("disk", "cleanup", "resources"):
        if key in report:
            lines.append(f"- {key}: `{json.dumps(report[key], sort_keys=True)}`")
    return "\n".join(lines) + "\n"


def compact(run: dict[str, Any]) -> dict[str, Any]:
    for phase in ("unloaded", "loaded"):
        run[phase]["samples"] = [list(sample) for sample in run[phase]["samples"]]
    return run


def write_report(report: dict[str, Any], out: Path) -> None:
    out.mkdir(parents=True, exist_ok=True)
    (out / f"{report['window']}-report.json").write_text(json.dumps(report, indent=1, sort_keys=True) + "\n")
    (out / f"{report['window']}-summary.md").write_text(markdown(report))


def measure(client: Client, args: argparse.Namespace, samples_path: Path, slot_end: float) -> dict[str, Any]:
    report: dict[str, Any] = {"window": args.window, "mode": args.mode, "revision": args.revision,
                              "host": host_info(), "started": time.time(), "runs": []}
    plans = [0] * args.runs + ([1] if args.sensitivity else [])
    for extra_groups in plans:
        if time.time() + RUN_SECONDS[args.mode] > slot_end:
            report["stoppedEarly"] = "the next run would end after the assigned slot"
            break
        try:
            run = compact(run_once(client, args.mode, extra_groups))
        except Exception as error:
            report["runs"].append({"sensitivity": bool(extra_groups), "error": repr(error), "evaluation": {
                "verdict": "invalid", "fail": [], "invalid": [f"the run stopped: {error!r}"]}})
            print(f"run {len(report['runs'])}: stopped: {error!r}", flush=True)
            break
        run["sensitivity"] = bool(extra_groups)
        run["evaluation"] = evaluate(run)
        run["resources"] = resource_summary(read_samples(samples_path), run["phaseTimes"]["loadedStart"],
                                            run["phaseTimes"]["loadedEnd"])
        report["runs"].append(run)
        print(f"run {len(report['runs'])}: {run['evaluation']['verdict']} {run['evaluation']['fail']} "
              f"{run['evaluation']['invalid']}", flush=True)
    measured = [run["evaluation"] for run in report["runs"] if not run["sensitivity"]]
    report["verdict"] = overall(measured) if len(measured) == args.runs else "invalid"
    report["finished"] = time.time()
    return report


# Commands


def command_preflight(args: argparse.Namespace) -> int:
    assigned = json.loads(Path(args.assigned).read_text())
    reasons = preflight(args.mode, args.window, assigned, host_processes(), time.time(), os.getpgid(0))
    slot_end = None if reasons else own_slot_end(args.window, assigned)
    print(json.dumps({"window": args.window, "host": host_load(), "refused": reasons, "slotEnd": slot_end}))
    return 2 if reasons else 0


def command_direct(args: argparse.Namespace) -> int:
    assigned = json.loads(Path(args.assigned).read_text())
    reasons = preflight("direct", args.window, assigned, host_processes(), time.time(), os.getpgid(0))
    if reasons:
        print(json.dumps({"refused": reasons, "host": host_load()}))
        return 2
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    directory = owned_directory()
    relay = sampler = None
    try:
        subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1",
                        "-nodes", "-days", "1", "-subj", "/CN=localhost",
                        "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1",
                        "-keyout", str(directory / "tls.key"), "-out", str(directory / "tls.crt")],
                       check=True, capture_output=True)
        relay = OwnedProcess(
            [sys.executable, "-c", "import sys; from gotsync_server.server import main; sys.exit(main())",
             "--host", "127.0.0.1", "--port", "0", "--metrics-host", "127.0.0.1", "--metrics-port", "0",
             "--delivery-host", "127.0.0.1", "--delivery-port", "0",
             "--tls-cert", str(directory / "tls.crt"), "--tls-key", str(directory / "tls.key"),
             "--database", str(directory / "mls.sqlite3"), "--enable-blobs",
             "--blob-directory", str(directory / "blobs" / "v1"), "--blob-database", str(directory / "blobs.sqlite3")],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env={**os.environ, "PYTHONUNBUFFERED": "1"})
        port = None
        lines = []
        while port is None:
            line = relay.process.stdout.readline()
            if not line:
                raise RuntimeError(f"relay exited before it was ready: {lines}")
            lines.append(line.rstrip())
            if line.startswith("MLS delivery ready on 127.0.0.1:"):
                port = int(line.split(":")[1].split("/")[0])
        sampler = ProcessSampler(relay.process.pid, directory / "samples.jsonl")
        client = Client("direct", "127.0.0.1", port, "localhost", str(directory / "tls.crt"))
        report = measure(client, args, directory / "samples.jsonl", own_slot_end(args.window, assigned))
        sampler.close()
        sampler = None
        report["disk"] = {"blobBytes": sum(path.stat().st_size for path in (directory / "blobs").rglob("*")
                                           if path.is_file()),
                          "databaseBytes": sum(path.stat().st_size for path in directory.glob("blobs.sqlite3*"))}
        relay.stop()
        report["relayLog"] = lines + [line.rstrip() for line in relay.process.stdout if line.strip()]
        relay = None
        report["cleanup"] = {"relayStopped": True}
        write_report(report, Path(args.out))
        return 0 if report["verdict"] == "pass" else 1
    finally:
        try:
            if sampler is not None:
                sampler.close()
            if relay is not None:
                relay.stop()
        finally:
            remove_owned_directory(directory, directory)


def command_run(args: argparse.Namespace) -> int:
    client = Client(args.mode, args.via, args.port, args.host, args.ca)
    report = measure(client, args, Path(args.samples), args.slot_end)
    write_report(report, Path(args.out))
    return 0 if report["verdict"] == "pass" else 1


def command_annotate(args: argparse.Namespace) -> int:
    path = Path(args.report)
    report = json.loads(path.read_text())
    report.update(json.loads(args.values))
    if args.host_info:
        report["hostMachine"] = host_info()
    if args.samples:
        samples = read_samples(Path(args.samples))
        for run in report["runs"]:
            if "phaseTimes" not in run:
                continue
            run["resources"] = resource_summary(samples, run["phaseTimes"]["loadedStart"],
                                                run["phaseTimes"]["loadedEnd"])
    write_report(report, path.parent)
    return 0


def command_verify_clean(args: argparse.Namespace) -> int:
    leftovers = docker_leftovers(args.project)
    print(json.dumps({"project": args.project, "leftovers": leftovers}))
    return 1 if leftovers else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("preflight", "direct", "run"):
        command = commands.add_parser(name)
        command.add_argument("--window", required=True)
        if name != "run":
            command.add_argument("--assigned", required=True, help="JSON list of assigned windows")
        if name == "preflight":
            command.add_argument("--mode", required=True, choices=("direct", "traefik"))
        else:
            command.add_argument("--runs", type=int, default=3)
            command.add_argument("--sensitivity", action="store_true")
            command.add_argument("--revision", default="unknown")
            command.add_argument("--out", required=True)
    run = commands.choices["run"]
    run.add_argument("--mode", default="traefik", choices=("traefik",))
    run.add_argument("--via", required=True)
    run.add_argument("--port", type=int, default=443)
    run.add_argument("--host", required=True)
    run.add_argument("--ca", required=True)
    run.add_argument("--samples", required=True)
    run.add_argument("--slot-end", type=float, required=True)
    annotate = commands.add_parser("annotate")
    annotate.add_argument("--report", required=True)
    annotate.add_argument("--values", default="{}")
    annotate.add_argument("--samples")
    annotate.add_argument("--host-info", action="store_true")
    verify = commands.add_parser("verify-clean")
    verify.add_argument("--project", required=True)
    args = parser.parse_args(argv)
    if args.command == "direct":
        args.mode = "direct"
    return {"preflight": command_preflight, "direct": command_direct, "run": command_run,
            "annotate": command_annotate, "verify-clean": command_verify_clean}[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
