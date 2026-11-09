import importlib.util
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("bench", Path(__file__).parents[1] / "bench-blob-isolation.py")
bench = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = bench
SPEC.loader.exec_module(bench)

SLOT = [{"id": "l3a2b-direct-1", "start": "2027-01-15T08:00:00Z", "end": "2027-01-15T08:15:00Z"},
        {"id": "a2b2a-reference", "start": "2027-01-15T08:20:00Z", "end": "2027-01-15T08:40:00Z"}]
INSIDE = bench.parse_time("2027-01-15T08:01:00Z")
BEFORE = INSIDE - 3600


def phase(latency=0.010, statuses=None, membership=None):
    samples = [(("fetch", "append", "ack")[index % 3], 200, latency) for index in range(3 * bench.CYCLES)]
    for index, status in enumerate(statuses or []):
        samples[index] = (samples[index][0], status, latency)
    return {
        "samples": samples, "seconds": 20.0,
        "membership": membership or {
            "remove": {"status": 200}, "add": {"status": 200}, "leave": {"status": 200},
            "writers": {"active": ["A", "E"], "expectedActive": ["A", "E"],
                        "inactive": ["B8", "B9"], "expectedInactive": ["B8", "B9"]},
        },
    }


def blob(put_times=None, get_times=None):
    steady = [float(second) + 0.5 for second in range(20)]
    return {"putTimes": steady if put_times is None else put_times,
            "getTimes": steady if get_times is None else get_times,
            "windowStart": 0.0, "windowEnd": 20.0, "mismatches": 0}


def run(**changes):
    return {"unloaded": phase(), "loaded": phase(), "blob": blob(), **changes}


class EvaluatorTests(unittest.TestCase):
    def test_percentile_is_nearest_rank(self):
        samples = [float(value) for value in range(1, 101)]
        self.assertEqual(bench.percentile(samples, 95), 95.0)
        self.assertEqual(bench.percentile(samples, 99), 99.0)
        self.assertEqual(bench.percentile([3.0], 99), 3.0)

    def test_equal_phases_with_sustained_blob_load_pass(self):
        evaluation = bench.evaluate(run())
        self.assertEqual((evaluation["verdict"], evaluation["fail"], evaluation["invalid"]), ("pass", [], []))

    def test_each_threshold_fails_the_run(self):
        slow = phase()
        slow["samples"][-31:] = [(name, 200, 0.4) for name, _, _ in slow["samples"][-31:]]
        tail = phase()
        tail["samples"][-7:] = [(name, 200, 1.2) for name, _, _ in tail["samples"][-7:]]
        cases = {
            "p95 delta": run(loaded=slow),
            "p99 delta": run(loaded=tail),
            "control 429/503": run(loaded=phase(statuses=[429])),
            "unexpected control statuses": run(unloaded=phase(statuses=[0])),
            "remove ended": run(loaded=phase(membership={**phase()["membership"], "remove": {"status": 409}})),
            "add ended": run(loaded=phase(membership={**phase()["membership"], "add": {"status": 0}})),
            "leave ended": run(unloaded=phase(membership={**phase()["membership"], "leave": {"status": 403}})),
            "writer membership": run(loaded=phase(membership={
                **phase()["membership"], "writers": {"active": ["A", "B9"], "expectedActive": ["A", "E"]}})),
        }
        for reason, sample in cases.items():
            with self.subTest(reason=reason):
                evaluation = bench.evaluate(sample)
                self.assertEqual(evaluation["verdict"], "fail")
                self.assertTrue(any(reason in text for text in evaluation["fail"]), evaluation["fail"])

    def test_deltas_just_under_the_thresholds_pass(self):
        edge = phase()
        edge["samples"][-31:] = [(name, 200, 0.25) for name, _, _ in edge["samples"][-31:]]
        edge["samples"][-7:] = [(name, 200, 1.0) for name, _, _ in edge["samples"][-7:]]
        self.assertEqual(bench.evaluate(run(loaded=edge))["verdict"], "pass")

    def test_stalled_or_incomplete_runs_are_invalid_not_passing(self):
        front_loaded = [value / 10 for value in range(60)]
        cases = {
            "blob put": run(blob=blob(put_times=[1.0, 2.0])),
            "blob get": run(blob=blob(get_times=front_loaded)),
            "control samples": run(loaded={**phase(), "samples": phase()["samples"][:-3]}),
            "mismatched": run(blob={**blob(), "mismatches": 1}),
            "time bound": run(overran=True),
        }
        for reason, sample in cases.items():
            with self.subTest(reason=reason):
                evaluation = bench.evaluate(sample)
                self.assertEqual(evaluation["verdict"], "invalid")
                self.assertTrue(any(reason in text for text in evaluation["invalid"]), evaluation["invalid"])

    def test_a_threshold_failure_outranks_an_invalid_run(self):
        evaluation = bench.evaluate(run(loaded=phase(statuses=[503]), blob=blob(put_times=[])))
        self.assertEqual(evaluation["verdict"], "fail")
        self.assertTrue(evaluation["invalid"])

    def test_overall_requires_every_run_to_pass(self):
        self.assertEqual(bench.overall([{"verdict": "pass"}] * 3), "pass")
        self.assertEqual(bench.overall([{"verdict": "pass"}, {"verdict": "invalid"}]), "invalid")
        self.assertEqual(bench.overall([{"verdict": "invalid"}, {"verdict": "fail"}]), "fail")

    def test_docker_stats_samples_are_summarized_per_container_inside_the_window(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "samples.jsonl"
            path.write_text(
                '{"t":10,"Name":"relay","CPUPerc":"12.50%","MemUsage":"64MiB / 512MiB"}\n'
                '{"t":11,"Name":"relay","CPUPerc":"7.50%","MemUsage":"80.5MiB / 512MiB"}\n'
                '{"t":30,"Name":"relay","CPUPerc":"99%","MemUsage":"500MiB / 512MiB"}\n'
                '{"t":10.5,"name":"traefik","cpu":3.0,"memBytes":1000}\nnot json\n')
            summary = bench.resource_summary(bench.read_samples(path), 9, 20)
        self.assertEqual(summary["relay"], {"meanCpuPercent": 10.0, "peakMemBytes": int(80.5 * 1024**2),
                                            "samples": 2})
        self.assertEqual(summary["traefik"]["peakMemBytes"], 1000)


class AggregateReportTests(unittest.TestCase):
    def test_window_counts_every_blob_request_and_transfer_inside_the_loaded_phase(self):
        load = bench.BlobLoad(None, None, 0)
        load.events = [(1.0, 1.0, "begin", "200"), (2.0, 2.0, "put", "200"), (3.0, 3.0, "put", "429 rateLimited"),
                       (4.0, 4.0, "get", "0"), (5.0, 5.0, "get", "200"), (6.0, 6.0, "get", "afterTransition 403"),
                       (30.0, 30.0, "put", "200")]
        load.transfers = [(2.0, "put", 524304), (5.0, "get", 17), (30.0, "put", 17)]
        window = load.window(0.0, 10.0)
        self.assertEqual((window["offeredPerSecond"], window["acceptedPerSecond"], window["resets"]), (0.6, 0.3, 1))
        self.assertEqual(window["operations"]["put"], {"offered": 2, "completed": 2, "accepted": 1,
                                                       "statuses": {"200": 1, "429 rateLimited": 1}})
        self.assertEqual(window["operations"]["get"]["statuses"], {"0": 1, "200": 1, "afterTransition 403": 1})
        self.assertEqual((window["putBytes"], window["getBytes"]), (524304, 17))

    def test_offered_requests_and_completed_transfers_use_their_own_times(self):
        load = bench.BlobLoad(None, None, 0)
        writer = bench.Writer("A")
        load.record(writer, "put")(bench.Response(200, {}, b"", 2.0, 9.0, 11.0))
        load.record(writer, "get")(bench.Response(200, {}, b"", 2.0, -1.0, 1.0))
        load.record(writer, "begin")(bench.Response(429, {}, b"", 1.0, 10.0, 11.0))
        load.transfers = [(11.0, "put", 524304), (1.0, "get", 17)]
        window = load.window(0.0, 10.0)
        self.assertEqual((window["offeredPerSecond"], window["completedPerSecond"],
                          window["acceptedPerSecond"]), (0.1, 0.1, 0.1))
        self.assertIn("put", window["operations"])
        self.assertIn("get", window["operations"])
        self.assertEqual(window["operations"]["put"],
                         {"offered": 1, "completed": 0, "accepted": 0, "statuses": {}})
        self.assertEqual(window["operations"]["get"],
                         {"offered": 0, "completed": 1, "accepted": 1, "statuses": {"200": 1}})
        self.assertNotIn("begin", window["operations"])
        self.assertEqual((window["putBytes"], window["getBytes"]), (0, 17))

    def test_quarter_boundary_is_counted_in_only_one_interval(self):
        rate, empty = bench.sustained([5.0, 10.0, 15.0, 20.0], 0.0, 20.0)
        self.assertEqual((rate, empty), (0.15, 1))

    def test_summary_reports_aggregate_rates_and_disclaims_saturation(self):
        sample = run()
        sample["blob"]["window"] = bench.BlobLoad(None, None, 0).window(0.0, 20.0)
        sample["evaluation"] = bench.evaluate(sample)
        text = bench.markdown({"window": "w", "mode": "direct", "verdict": "pass", "runs": [sample]})
        self.assertIn("not per-writer saturation or a maximum-throughput result", text)
        self.assertIn("| 1 | pass |", text)


class GuardTests(unittest.TestCase):
    def test_destinations_are_loopback_or_the_owned_test_network(self):
        bench.check_destination("direct", "127.0.0.1", "localhost")
        bench.check_destination("direct", "::1", "localhost")
        bench.check_destination("traefik", "198.51.100.2", "relay.example.test")
        for mode, via, host in (
            ("direct", "10.0.0.5", "localhost"),
            ("direct", "127.0.0.1", "relay.example.com"),
            ("direct", "localhost", "localhost"),
            ("traefik", "203.0.113.7", "relay.example.test"),
            ("traefik", "198.51.100.2", "relay.gotsync.app"),
            ("traefik", "relay.example.test", "relay.example.test"),
            ("production", "127.0.0.1", "localhost"),
        ):
            with self.subTest(mode=mode, via=via, host=host), self.assertRaises(ValueError):
                bench.check_destination(mode, via, host)

    def test_preflight_accepts_only_the_assigned_reserved_slot(self):
        self.assertEqual(bench.preflight("direct", "l3a2b-direct-1", SLOT, [], INSIDE, 1), [])
        cases = {
            "not the reserved traefik window": ("traefik", "l3a2b-direct-1", SLOT, INSIDE),
            "not the reserved direct window": ("direct", "l3a2b-other", SLOT, INSIDE),
            "no single assigned slot": ("direct", "l3a2b-direct-1", SLOT[1:], INSIDE),
            "outside the assigned slot": ("direct", "l3a2b-direct-1", SLOT, BEFORE),
        }
        for reason, (mode, window, assigned, now) in cases.items():
            with self.subTest(reason=reason):
                self.assertTrue(any(reason in text for text in bench.preflight(mode, window, assigned, [], now, 1)))

    def test_preflight_rejects_an_overlapping_assigned_window(self):
        overlapping = SLOT + [{"id": "c1-reference", "start": "2027-01-15T07:00:00Z", "end": "2027-01-15T09:00:00Z"}]
        reasons = bench.preflight("direct", "l3a2b-direct-1", overlapping, [], INSIDE, 1)
        self.assertEqual(reasons, ["assigned window 'c1-reference' is active"])

    def test_preflight_rejects_coordinated_jobs_and_ignores_idle_simulators_and_itself(self):
        processes = [
            (10, 10, "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test -scheme GotDone"),
            (11, 11, "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/xctest"),
            (12, 12, "/usr/bin/python3 scripts/bench-blob-isolation.py direct --window other"),
            (20, 20, "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/XPCServices/launchd_sim"),
            (21, 21, "/usr/bin/simctl list"),
            (30, 99, "/bin/bash scripts/bench-blob-isolation.sh direct --window l3a2b-direct-1"),
            (31, 31, ""),
        ]
        reasons = bench.preflight("direct", "l3a2b-direct-1", SLOT, processes, INSIDE, 99)
        self.assertEqual(reasons, ["coordinated job running: pid 10 xcodebuild",
                                   "coordinated job running: pid 11 xctest",
                                   "coordinated job running: pid 12 python3"])


class CleanupTests(unittest.TestCase):
    def test_surviving_load_thread_refuses_a_clean_stop(self):
        class SurvivingThread:
            def join(self, timeout):
                self.timeout = timeout

            def is_alive(self):
                return True

        writer = bench.Writer("A")
        writer.threads = [SurvivingThread(), SurvivingThread()]
        with self.assertRaisesRegex(RuntimeError, "blob load threads did not stop"):
            bench.BlobLoad(None, None, 0).stop([writer])
        self.assertTrue(writer.stop.is_set())
        self.assertTrue(all(0 <= thread.timeout <= bench.REQUEST_TIMEOUT + 5 for thread in writer.threads))

    def test_all_groups_are_halted_and_drained_after_one_group_fails(self):
        calls = []

        class Load:
            def __init__(self, name):
                self.name = name
                self.group = SimpleNamespace(writers=[])

            def halt(self, writers):
                calls.append(("halt", self.name))

            def stop(self, writers, deadline):
                calls.append(("stop", self.name))
                if self.name == "first":
                    raise RuntimeError("surviving worker")

        with self.assertRaisesRegex(RuntimeError, "surviving worker"):
            bench.stop_loads([Load("first"), Load("second")])
        self.assertEqual(calls, [("halt", "first"), ("halt", "second"), ("stop", "first"), ("stop", "second")])

    def test_measure_reserves_teardown_time_before_starting_a_run(self):
        args = SimpleNamespace(mode="direct", window="w", revision="test", runs=1, sensitivity=False)
        with patch.object(bench, "host_info", return_value={}), patch.object(bench.time, "time", return_value=100), \
                patch.object(bench, "run_once") as run_once:
            report = bench.measure(None, args, Path("unused"),
                                   100 + bench.RUN_SECONDS["direct"] + bench.TEARDOWN_SECONDS - 1)
        run_once.assert_not_called()
        self.assertEqual(report["verdict"], "invalid")
        self.assertIn("teardown", report["stoppedEarly"])

    def test_surviving_load_stops_the_mode_before_another_run(self):
        args = SimpleNamespace(mode="direct", window="w", revision="test", runs=3, sensitivity=False)
        with patch.object(bench, "host_info", return_value={}), patch.object(bench.time, "time", return_value=100), \
                patch.object(bench, "run_once", side_effect=RuntimeError("blob load threads did not stop")) as run_once:
            report = bench.measure(None, args, Path("unused"), 1000)
        self.assertEqual(run_once.call_count, 1)
        self.assertEqual(report["verdict"], "invalid")
        self.assertEqual(len(report["runs"]), 1)
        self.assertIn("blob load threads did not stop", report["runs"][0]["error"])

    def assert_group_gone(self, group):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try:
                os.killpg(group, 0)
            except ProcessLookupError:
                return
            time.sleep(0.05)
        self.fail(f"process group {group} survived")

    def test_stop_terminates_only_the_owned_process_group(self):
        bystander = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"], start_new_session=True)
        self.addCleanup(bystander.wait)
        self.addCleanup(bystander.kill)
        owned = bench.OwnedProcess(["/bin/sh", "-c", "sleep 30 & wait"])
        self.assertEqual(owned.stop(grace=5), -signal.SIGTERM)
        self.assert_group_gone(owned.group)
        self.assertIsNone(bystander.poll())

    def test_stop_kills_a_group_that_ignores_term_after_the_grace_period(self):
        script = "import signal, sys, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); print(1, flush=True); time.sleep(30)"
        owned = bench.OwnedProcess([sys.executable, "-c", script], stdout=subprocess.PIPE)
        owned.process.stdout.readline()
        started = time.monotonic()
        self.assertEqual(owned.stop(grace=0.5), -signal.SIGKILL)
        self.assertLess(time.monotonic() - started, 5)
        owned.process.stdout.close()
        self.assert_group_gone(owned.group)

    def test_stop_after_exit_is_harmless(self):
        reaped = bench.OwnedProcess(["/usr/bin/true"])
        reaped.process.wait()
        self.assertEqual(reaped.stop(grace=1), 0)
        unreaped = bench.OwnedProcess(["/bin/sh", "-c", "exit 3"])
        time.sleep(0.2)
        self.assertEqual(unreaped.stop(grace=1), 3)

    def test_only_the_created_directory_is_removed(self):
        created = bench.owned_directory()
        (created / "blobs").mkdir()
        with tempfile.TemporaryDirectory() as other:
            for path in (Path(other), created.parent):
                with self.subTest(path=path), self.assertRaises(ValueError):
                    bench.remove_owned_directory(path, created)
            self.assertTrue(Path(other).exists())
        bench.remove_owned_directory(created, created)
        self.assertFalse(created.exists())

    def test_docker_leftovers_query_only_the_project_labels(self):
        commands = []

        def docker(command, **_):
            commands.append(command)
            label = command[-1]
            listed = "abc123\n" if command[1] == "network" and label.endswith("gotsync.bench=p1") else ""
            return subprocess.CompletedProcess(command, 0, stdout=listed)

        self.assertEqual(bench.docker_leftovers("p1", run=docker), ["network abc123"])
        self.assertEqual(len(commands), 6)
        self.assertIn(["docker", "container", "ls", "-a", "-q", "--filter", "label=com.docker.compose.project=p1"],
                      commands)
        self.assertTrue(all(command[-1] in ("label=com.docker.compose.project=p1", "label=gotsync.bench=p1")
                            for command in commands))
        self.assertEqual(bench.docker_leftovers("p1", run=lambda command, **_: subprocess.CompletedProcess(
            command, 0, stdout="")), [])


if __name__ == "__main__":
    unittest.main()
