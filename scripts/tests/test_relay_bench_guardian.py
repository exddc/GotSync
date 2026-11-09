import importlib.util
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

SPEC = importlib.util.spec_from_file_location("guardian", Path(__file__).parents[1] / "bench-guardian.py")
guardian = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = guardian
SPEC.loader.exec_module(guardian)

Process = guardian.Process
BIRTH, LATER = "birth-1", "birth-2"


class TrackerTests(unittest.TestCase):
    def test_exec_keeps_ownership_and_a_reused_pid_gains_none(self):
        table = {100: Process(1, 100, BIRTH, False, "bash bench.sh guarded-direct"),
                 200: Process(100, 200, BIRTH, False, "python relay")}
        tracker = guardian.Tracker(100)
        tracker.update(table)
        table[100] = Process(1, 100, BIRTH, False, "python -I bench.py direct")
        table[200] = Process(1, 200, BIRTH, False, "python relay")
        tracker.update(table)
        self.assertEqual(tracker.live(table), [100, 200])
        table[200] = Process(1, 200, LATER, False, "someone else")
        table[300] = Process(200, 300, LATER, False, "child of the reused pid")
        tracker.update(table)
        self.assertEqual(tracker.live(table), [100])
        self.assertNotIn(300, tracker.owned)

    def test_a_zombie_is_not_live_work(self):
        table = {100: Process(1, 100, BIRTH, True, "")}
        tracker = guardian.Tracker(100)
        tracker.update(table)
        self.assertEqual(tracker.live(table), [])
        self.assertEqual(guardian.group_members(table, 100), [])

    def test_a_group_with_a_live_unowned_member_is_never_signalled(self):
        table = {100: Process(1, 100, BIRTH, False, "bench"),
                 200: Process(100, 200, BIRTH, False, "relay"),
                 300: Process(1, 200, LATER, False, "peer in the same group"),
                 400: Process(1, 100, LATER, True, "exited peer zombie")}
        tracker = guardian.Tracker(100)
        tracker.update(table)
        allowed, refused = guardian.signal_plan(table, tracker, [100, 200])
        self.assertEqual(allowed, [100])
        self.assertEqual(refused, ["group 200 has unowned members [300]; not signalled"])

    def test_proc_snapshot_reads_parent_group_birth_and_state(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for pid, record, command in ((7, "7 (sh) S 1 7 7 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 555 0", b"sh\0-c\0x"),
                                         (8, "8 (a) b) Z 7 7 7 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 777 0", b"")):
                (root / str(pid)).mkdir()
                (root / str(pid) / "stat").write_text(record)
                (root / str(pid) / "cmdline").write_bytes(command)
            table = guardian.proc_snapshot(root)
        self.assertEqual(table[7], Process(1, 7, "555", False, "sh -c x"))
        self.assertEqual(table[8], Process(7, 7, "777", True, ""))


class DockerTests(unittest.TestCase):
    def test_every_call_is_capped_by_the_absolute_deadline(self):
        timeouts = []

        def run(command, **options):
            timeouts.append(options["timeout"])
            return subprocess.CompletedProcess(command, 0, stdout="")

        guardian.Docker(time.time() + 100, run)(["ps"])
        guardian.Docker(time.time() + 2, run)(["ps"])
        self.assertEqual(guardian.Docker(time.time() - 1, run)(["ps"]), None)
        self.assertEqual(timeouts[0], guardian.DOCKER_TIMEOUT)
        self.assertLessEqual(timeouts[1], 2)
        self.assertEqual(len(timeouts), 2)

    def test_leftovers_use_only_the_exact_project_labels(self):
        commands = []

        def run(command, **options):
            commands.append(command)
            listed = "n1\n" if command[1] == "network" and command[-1] == "label=gotsync.bench=p-1" else ""
            return subprocess.CompletedProcess(command, 0, stdout=listed)

        leftovers = guardian.Docker(time.time() + 60, run).leftovers("p-1")
        self.assertEqual(leftovers, {"container": [], "network": ["n1"], "volume": []})
        self.assertTrue(all(command[-1] in ("label=com.docker.compose.project=p-1", "label=gotsync.bench=p-1")
                            for command in commands))

    def test_unreadable_docker_state_is_unknown_not_clean(self):
        def run(command, **options):
            raise subprocess.TimeoutExpired(command, options["timeout"])

        self.assertIsNone(guardian.Docker(time.time() + 60, run).leftovers("p-1"))


class GuardTests(unittest.TestCase):
    def setUp(self):
        self.events = []

    def log(self, event, **values):
        self.events.append((event, values))

    def guard(self, script, seconds, term_margin, kill_margin):
        return guardian.guard([sys.executable, "-c", script], time.time() + seconds, cwd=tempfile.gettempdir(),
                              log=self.log, term_margin=term_margin, kill_margin=kill_margin)

    def alive(self, pid):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        table = guardian.snapshot()
        return pid in table and not table[pid].zombie

    def test_a_cooperative_mode_reports_its_exit_code_and_proven_cleanup_separately(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "stop-at"
            script = f"import os, pathlib, sys; pathlib.Path({str(marker)!r}).write_text(" \
                     "os.environ['GOTSYNC_BENCH_STOP_AT']); sys.exit(1)"
            started = time.time()
            result = self.guard(script, 20, 6, 3)
            self.assertAlmostEqual(float(marker.read_text()), started + 14, delta=1)
        self.assertEqual((result["exitCode"], result["cleanupProven"], result["incomplete"]), (1, True, []))
        self.assertNotIn("term", [event for event, _ in self.events])

    def test_a_stuck_mode_is_stopped_and_only_owned_groups_are_killed(self):
        bystander = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"], start_new_session=True)
        self.addCleanup(bystander.wait)
        self.addCleanup(bystander.kill)
        with tempfile.TemporaryDirectory() as directory:
            pid_file = Path(directory) / "grandchild"
            script = ("import pathlib, signal, subprocess, sys, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                      "child = subprocess.Popen([sys.executable, '-c', 'import signal, time; "
                      "signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)'], start_new_session=True); "
                      f"pathlib.Path({str(pid_file)!r}).write_text(str(child.pid)); time.sleep(60)")
            started = time.monotonic()
            result = self.guard(script, 4.5, 3.5, 2)
            grandchild = int(pid_file.read_text())
        events = [event for event, _ in self.events]
        self.assertEqual(events.count("term"), 1)
        self.assertEqual(events.count("kill"), 2)
        self.assertEqual((result["exitCode"], result["cleanupProven"]), (-signal.SIGKILL, True))
        self.assertFalse(self.alive(grandchild))
        self.assertIsNone(bystander.poll())
        self.assertLess(time.monotonic() - started, 4.5)

    def test_a_mode_whose_trap_cleans_up_after_term_is_not_killed(self):
        script = ("import signal, sys, time; signal.signal(signal.SIGTERM, lambda *_: sys.exit(143)); "
                  "time.sleep(60)")
        result = self.guard(script, 5, 4, 1)
        self.assertEqual((result["exitCode"], result["cleanupProven"]), (143, True))
        self.assertNotIn("kill", [event for event, _ in self.events])

    def test_interrupting_the_guardian_stops_its_mode_and_still_proves_cleanup(self):
        script = ("import signal, sys, time; signal.signal(signal.SIGTERM, lambda *_: sys.exit(143)); "
                  "time.sleep(60)")
        timer = threading.Timer(1.0, os.kill, (os.getpid(), signal.SIGTERM))
        timer.start()
        self.addCleanup(timer.cancel)
        started = time.monotonic()
        result = self.guard(script, 120, 90, 30)
        self.assertEqual((result["exitCode"], result["interrupted"], result["cleanupProven"]), (143, True, True))
        self.assertLess(time.monotonic() - started, 10)
        self.assertEqual(signal.getsignal(signal.SIGTERM), signal.SIG_DFL)

    def test_no_mode_starts_without_usable_time_in_the_slot(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "started"
            result = self.guard(f"import pathlib; pathlib.Path({str(marker)!r}).touch()", 2, 3, 1)
            self.assertFalse(marker.exists())
        self.assertEqual((result["started"], result["exitCode"]), (False, None))
        self.assertEqual(self.events[0][0], "refused")

    def test_main_refuses_a_window_without_one_assigned_slot(self):
        with tempfile.TemporaryDirectory() as directory:
            assigned = Path(directory) / "windows.json"
            assigned.write_text("[]")
            with mock.patch("sys.stderr"):
                code = guardian.main(["--window", "w", "--assigned", str(assigned), "--log",
                                      str(Path(directory) / "g.jsonl"), "--repo", directory, "--", "true"])
        self.assertEqual(code, 2)


if __name__ == "__main__":
    unittest.main()
