import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "check-host-spi-surface.py"
SPEC = importlib.util.spec_from_file_location("host_surface", SCRIPT)
SURFACE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SURFACE)


def symbol(path, spi=True):
    return {"identifier": {"precise": "s:7GotSync." + ".".join(path)}, "pathComponents": path, "spi": spi}


class HostSPISurfaceTests(unittest.TestCase):
    def graph(self):
        values = [symbol([name]) for name in SURFACE.SURFACE_TYPES | SURFACE.BLOB_SURFACE_TYPES]
        values += [symbol([owner, member]) for owner, members in SURFACE.SURFACE_MEMBERS.items() for member in members]
        values += [symbol(["HostJournal", member]) for member in SURFACE.REQUIRED_HOST_CALLS]
        values += [symbol(["BlobTransferService", member]) for member in SURFACE.REQUIRED_BLOB_CALLS]
        return {"symbols": values, "relationships": []}

    def check(self, graph):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "GotSync.symbols.json").write_text(json.dumps(graph))
            return subprocess.run([sys.executable, str(SCRIPT), "--graph-dir", directory], capture_output=True, text=True)

    def test_reviewed_surface_passes(self):
        result = self.check(self.graph())
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_an_extra_public_journal_command_is_refused(self):
        graph = self.graph()
        graph["symbols"].append(symbol(["HostJournal", "promote()"]))
        result = self.check(graph)
        self.assertEqual(result.returncode, 1)
        self.assertIn("unreviewed host call HostJournal.promote()", result.stderr)

    def test_an_extra_blob_service_call_is_refused(self):
        graph = self.graph()
        graph["symbols"].append(symbol(["BlobTransferService", "bind(route:)"]))
        result = self.check(graph)
        self.assertEqual(result.returncode, 1)
        self.assertIn("unreviewed blob call BlobTransferService.bind(route:)", result.stderr)

    def test_a_blob_surface_naming_its_store_is_refused(self):
        graph = self.graph()
        leaking = symbol(["BlobSummary", "store"])
        leaking["declarationFragments"] = [{"kind": "typeIdentifier", "spelling": "BlobStateStore",
                                            "preciseIdentifier": "s:7GotSync14BlobStateStoreC"}]
        graph["symbols"].append(leaking)
        result = self.check(graph)
        self.assertEqual(result.returncode, 1)
        self.assertIn("references BlobStateStore", result.stderr)

    def test_preexisting_non_spi_api_is_outside_the_surface(self):
        graph = self.graph()
        existing = symbol(["SyncConfiguration", "storageDirectory"], spi=False)
        existing["declarationFragments"] = [{"kind": "typeIdentifier", "spelling": "URL", "preciseIdentifier": "s:10Foundation3URLV"}]
        graph["symbols"].append(existing)
        result = self.check(graph)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
