"""Owned hard-deadline guardian for one benchmark mode inside its assigned UTC slot.

Starts the mode in its own session, with GOTSYNC_BENCH_STOP_AT set to slot end - TERM_MARGIN, and tracks every
descendant by birth identity, including separate sessions such as the direct relay. It asks the mode to stop at
that time, letting the mode's own traps clean up, and forcibly stops only process groups whose live members are all
its own at slot end - KILL_MARGIN. It then verifies, before the slot end, that no owned process and no exact
project-labelled Docker resource remains. A zombie is not live work. The mode's exit code and the cleanup result
are reported separately; incomplete cleanup exits 3 so that no further mode is started.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, NamedTuple

TERM_MARGIN = 90
KILL_MARGIN = 30
DOCKER_TIMEOUT = 8
POLL_SECONDS = 0.5
PROJECT_PREFIX = "gotsync-blob-bench-"


class Process(NamedTuple):
    ppid: int
    group: int
    birth: str
    zombie: bool
    command: str


Table = dict[int, Process]


def utc(value: str) -> float:
    return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def stamp(value: float | None = None) -> str:
    return datetime.fromtimestamp(time.time() if value is None else value, timezone.utc).isoformat(timespec="seconds")


def proc_snapshot(root: Path = Path("/proc")) -> Table:
    table = {}
    for entry in root.glob("[0-9]*"):
        try:
            record = (entry / "stat").read_text()
            fields = record[record.rfind(")") + 2:].split()
            command = (entry / "cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace").strip()
        except (OSError, ValueError):
            continue
        table[int(entry.name)] = Process(int(fields[1]), int(fields[2]), fields[19], fields[0] == "Z", command)
    return table


def ps_snapshot(timeout: float = 5) -> Table:
    output = subprocess.run(["ps", "-axo", "pid=,ppid=,pgid=,stat=,lstart=,command="], capture_output=True,
                            text=True, timeout=timeout, check=True).stdout
    table = {}
    for line in output.splitlines():
        fields = line.split(None, 9)
        if len(fields) >= 9:
            table[int(fields[0])] = Process(int(fields[1]), int(fields[2]), " ".join(fields[4:9]),
                                            fields[3].startswith("Z"), fields[9] if len(fields) == 10 else "")
    return table


def snapshot() -> Table:
    return proc_snapshot() if sys.platform == "linux" else ps_snapshot()


class Tracker:
    """Every process seen below the root, keyed by pid and birth so that exec keeps ownership and a reused pid
    does not gain it."""

    def __init__(self, root: int) -> None:
        self.root = root
        self.owned: dict[int, Process] = {}

    def update(self, table: Table) -> None:
        frontier = [self.root] + [pid for pid in self.owned if self.same(pid, table)]
        seen: set[int] = set()
        while frontier:
            pid = frontier.pop()
            if pid in seen or pid not in table:
                continue
            seen.add(pid)
            if pid in self.owned and not self.same(pid, table):
                continue
            self.owned[pid] = table[pid]
            frontier += [child for child, process in table.items() if process.ppid == pid]

    def same(self, pid: int, table: Table) -> bool:
        return pid in table and pid in self.owned and self.owned[pid].birth == table[pid].birth

    def live(self, table: Table) -> list[int]:
        return sorted(pid for pid in self.owned if self.same(pid, table) and not table[pid].zombie)

    def groups(self) -> set[int]:
        return {process.group for process in self.owned.values()}


def group_members(table: Table, group: int) -> list[int]:
    return sorted(pid for pid, process in table.items() if process.group == group and not process.zombie)


def signal_plan(table: Table, tracker: Tracker, groups: list[int]) -> tuple[list[int], list[str]]:
    """Groups that may be signalled (every live member owned) and the reasons others may not."""
    allowed, refused = [], []
    for group in groups:
        members = group_members(table, group)
        strangers = [pid for pid in members if not tracker.same(pid, table)]
        if strangers:
            refused.append(f"group {group} has unowned members {strangers}; not signalled")
        elif members:
            allowed.append(group)
    return allowed, refused


class Docker:
    def __init__(self, deadline: float, run: Callable[..., subprocess.CompletedProcess] = subprocess.run) -> None:
        self.deadline, self.run = deadline, run

    def __call__(self, arguments: list[str]) -> list[str] | None:
        remaining = self.deadline - time.time()
        if remaining <= 0:
            return None
        try:
            result = self.run(["docker", *arguments], capture_output=True, text=True,
                              timeout=min(DOCKER_TIMEOUT, remaining))
        except (subprocess.TimeoutExpired, OSError):
            return None
        return result.stdout.split() if result.returncode == 0 else None

    def leftovers(self, project: str) -> dict[str, list[str]] | None:
        found: dict[str, list[str]] = {"container": [], "network": [], "volume": []}
        for kind in found:
            for label in (f"com.docker.compose.project={project}", f"gotsync.bench={project}"):
                names = self([kind, "ls", *(["-a"] if kind == "container" else []), "-q", "--filter",
                              f"label={label}"])
                if names is None:
                    return None
                found[kind] = sorted(set(found[kind]) | set(names))
        return found

    def remove(self, leftovers: dict[str, list[str]]) -> None:
        for kind, command in (("container", ["rm", "-f"]), ("network", ["network", "rm"]),
                              ("volume", ["volume", "rm"])):
            if leftovers[kind]:
                self(command + leftovers[kind])

    def labelled_projects(self, prefix: str) -> list[str] | None:
        projects: set[str] = set()
        for kind in ("container", "network"):
            names = self([kind, "ls", *(["-a"] if kind == "container" else []), "--filter", "label=gotsync.bench",
                          "--format", '{{.Label "gotsync.bench"}}'])
            if names is None:
                return None
            projects |= {name for name in names if name.startswith(prefix)}
        return sorted(projects)


def guard(command: list[str], end: float, *, cwd: str, log: Callable[..., None], docker: bool = False,
          term_margin: float = TERM_MARGIN, kill_margin: float = KILL_MARGIN,
          take_snapshot: Callable[[], Table] = snapshot, output: Callable[[str], None] = lambda line: None) -> dict:
    """Runs `command` until it exits or the slot's stop times arrive, then proves cleanup. SIGINT or SIGTERM to the
    guardian starts the same stop sequence at once, with the same grace period."""
    now = time.time()
    if now >= end - term_margin:
        log("refused", reason="no usable time left in the slot", slotEnd=stamp(end))
        return {"started": False, "exitCode": None, "cleanupProven": True, "incomplete": []}
    stop_at = end - term_margin
    log("start", command=command, stopAt=stamp(stop_at), killAt=stamp(end - kill_margin), slotEnd=stamp(end))
    child = subprocess.Popen(command, cwd=cwd, start_new_session=True, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, text=True,
                             env={**os.environ, "GOTSYNC_BENCH_STOP_AT": f"{stop_at:.3f}"})
    tracker = Tracker(child.pid)
    prefix = f"{PROJECT_PREFIX}{child.pid}-"
    projects: list[str] = []

    def pump() -> None:
        for line in child.stdout:
            output(line)
            match = re.fullmatch(r"== stack (" + re.escape(prefix) + r"\d+)", line.strip())
            if match:
                projects.append(match.group(1))
                log("project", name=match.group(1))

    reader = threading.Thread(target=pump, daemon=True)
    reader.start()
    kill_at = end - kill_margin
    interrupted: list[int] = []

    def interrupt(number: int, frame: object) -> None:
        nonlocal stop_at, kill_at
        if not interrupted:
            interrupted.append(number)
            now = time.time()
            stop_at = min(stop_at, now)
            kill_at = min(kill_at, now + term_margin - kill_margin)

    previous = {}
    if threading.current_thread() is threading.main_thread():
        for number in (signal.SIGINT, signal.SIGTERM):
            previous[number] = signal.signal(number, interrupt)
    termed = killed = False
    incomplete: list[str] = []
    while True:
        table = take_snapshot()
        tracker.update(table)
        now = time.time()
        if child.poll() is not None and not tracker.live(table):
            break
        if interrupted and not termed:
            log("interrupted", signal=interrupted[0])
        if not termed and now >= stop_at:
            termed = True
            allowed, refused = signal_plan(table, tracker, sorted(tracker.groups()))
            incomplete += refused
            log("term", groups=allowed, live=tracker.live(table))
            for group in allowed:
                try:
                    os.killpg(group, signal.SIGTERM)
                except (ProcessLookupError, PermissionError):
                    pass
        if now >= kill_at:
            killed = True
            allowed, refused = signal_plan(table, tracker, sorted(tracker.groups()))
            incomplete += refused
            for group in allowed:
                log("kill", group=group, members=group_members(table, group))
                try:
                    os.killpg(group, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass
            break
        time.sleep(POLL_SECONDS)
    for number, handler in previous.items():
        signal.signal(number, handler)

    try:
        exit_code = child.wait(timeout=max(0.1, min(5, end - 1 - time.time())))
    except subprocess.TimeoutExpired:
        exit_code = None
        incomplete.append("the mode's main process did not exit")
    reader.join(1)
    if not reader.is_alive():
        child.stdout.close()
    log("modeExited", exitCode=exit_code, termed=termed, killed=killed)
    cli = Docker(end - 1)
    table = take_snapshot()
    tracker.update(table)
    live = tracker.live(table)
    if live:
        incomplete.append(f"owned processes remain: {[(pid, tracker.owned[pid].command[:80]) for pid in live]}")
    if docker:
        labelled = cli.labelled_projects(prefix)
        if labelled is None:
            incomplete.append("docker labels could not be read before the slot end")
        names = sorted(set(projects) | set(labelled or []))
        for name in names:
            leftovers = cli.leftovers(name)
            if leftovers and any(leftovers.values()):
                log("dockerRemove", project=name, leftovers=leftovers)
                cli.remove(leftovers)
                leftovers = cli.leftovers(name)
            if leftovers is None:
                incomplete.append(f"docker state of {name} could not be read before the slot end")
            elif any(leftovers.values()):
                incomplete.append(f"docker leftovers for {name}: {leftovers}")
            else:
                log("dockerClean", project=name)
    finished = time.time()
    if finished >= end:
        incomplete.append("verification finished after the slot end")
    result = {"started": True, "exitCode": exit_code, "interrupted": bool(interrupted),
              "cleanupProven": not incomplete, "incomplete": incomplete,
              "ownedProcessesSeen": len(tracker.owned), "ownedGroups": sorted(tracker.groups()),
              "secondsBeforeEnd": round(end - finished, 1)}
    log("result", **result)
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--window", required=True)
    parser.add_argument("--assigned", required=True, help="JSON list of assigned windows")
    parser.add_argument("--log", required=True, help="JSON-lines event log; the mode's output goes next to it")
    parser.add_argument("--repo", required=True)
    parser.add_argument("--docker", action="store_true", help="verify the mode's Docker project is removed")
    parser.add_argument("command", nargs="+")
    args = parser.parse_args(argv)
    slot = [entry for entry in json.loads(Path(args.assigned).read_text()) if entry["id"] == args.window]
    if len(slot) != 1:
        print(f"no single assigned slot {args.window!r}", file=sys.stderr)
        return 2
    if time.time() < utc(slot[0]["start"]):
        print(f"the assigned slot {args.window!r} has not started", file=sys.stderr)
        return 2
    log_path = Path(args.log)
    log_path.parent.mkdir(parents=True, exist_ok=True)

    def log(event: str, **values) -> None:
        record = json.dumps({"t": stamp(), "event": event, **values})
        print(record, flush=True)
        with log_path.open("a") as stream:
            stream.write(record + "\n")

    with log_path.with_suffix(".out").open("a") as stream:
        def output(line: str) -> None:
            stream.write(line)
            stream.flush()
            print(line, end="", flush=True)

        result = guard(args.command, utc(slot[0]["end"]), cwd=args.repo, log=log, docker=args.docker,
                       output=output)
    if not result["cleanupProven"]:
        return 3
    if not result["started"]:
        return 2
    if result["exitCode"] is None:
        return 3
    return result["exitCode"] if result["exitCode"] >= 0 else 128 - result["exitCode"]


if __name__ == "__main__":
    sys.exit(main())
