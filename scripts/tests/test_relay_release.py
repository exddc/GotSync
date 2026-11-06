import contextlib
import importlib.util
import io
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("relay_release", Path(__file__).parents[1] / "relay-release.py")
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        environment = patch.dict(os.environ, {
            "GITHUB_REPOSITORY": "exddc/GotSync", "GITHUB_REF": "refs/heads/main",
            "GITHUB_RUN_ID": "123",
        })
        environment.start()
        self.addCleanup(environment.stop)
        self.manifest = {
            "schema": 1, "version": "0.1.0", "revision": "a" * 40,
            "inputs_sha256": "b" * 64, "image": "ghcr.io/exddc/gotsync-relay",
            "digest": "sha256:" + "c" * 64,
        }
        self.previous = {"tag_name": "relay-v0.1.0", "draft": False,
                         "assets": [{"name": "relay-release.json"}]}

    def test_relay_inputs_include_future_runtime_files_but_exclude_clients_tests_and_docs(self):
        for path in ["server/Dockerfile", "server/.dockerignore", "server/pyproject.toml",
                     "server/uv.lock", "server/LICENSE", "server/gotsync_server/server.py",
                     "server/gotsync_server/data/schema.json", "server/start-relay.sh",
                     "server/deploy/traefik/compose.yaml", "server/deploy/traefik/setup-host.sh"]:
            with self.subTest(path=path):
                self.assertTrue(release.relay_input(path))
        for path in ["Sources/GotSync/Engine/SyncEngine.swift", "README.md", "server/README.md",
                     "server/tests/test_server.py", "docs/PROTOCOL.md", "server/.env",
                     ".github/workflows/relay-release.yml", "scripts/relay-release.py"]:
            with self.subTest(path=path):
                self.assertFalse(release.relay_input(path))

    def test_fingerprint_tracks_content_deletions_modes_and_reverts_across_commits(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(release, "ROOT", Path(directory)):
            root = Path(directory)
            subprocess.run(["git", "init", "-q", directory], check=True)
            def commit():
                release.run("git", "add", ".")
                release.run("git", "-c", "user.name=Test", "-c", "user.email=test@example.test",
                            "commit", "-qm", "test: update inputs")
            source = root / "server/gotsync_server/server.py"
            source.parent.mkdir(parents=True)
            source.write_text("one")
            other = source.with_name("other.py")
            other.write_text("other")
            commit()
            original = release.input_hash()
            (root / "README.md").write_text("docs")
            commit()
            self.assertEqual(original, release.input_hash())
            source.write_text("two")
            commit()
            self.assertNotEqual(original, release.input_hash())
            source.write_text("one")
            commit()
            self.assertEqual(original, release.input_hash())
            source.chmod(0o755)
            commit()
            self.assertNotEqual(original, release.input_hash())
            source.chmod(0o644)
            other.unlink()
            commit()
            self.assertNotEqual(original, release.input_hash())

    def select(self, version, records, fingerprint="b" * 64, force=False):
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(release, "require_source", return_value="a" * 40), \
                patch.object(release, "run", return_value=""), \
                patch.object(release, "releases", return_value=records), \
                patch.object(release, "input_hash", return_value=fingerprint), \
                patch.object(release, "load_manifest", return_value=self.manifest), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            path = Path(directory) / "manifest.json"
            release.plan(version, path, force)
            manifest = json.loads(path.read_text()) if path.exists() else None
            return output.getvalue(), manifest

    def test_first_release_builds_once(self):
        output, manifest = self.select("0.1.0", [])
        self.assertIn("build=true", output)
        self.assertIn("publish=true", output)
        self.assertIsNone(manifest)

    def test_unchanged_inputs_do_not_publish_a_new_version(self):
        output, manifest = self.select("0.1.1", [self.previous])
        self.assertIn("build=false", output)
        self.assertIn("publish=false", output)
        self.assertIsNone(manifest)

    def test_changed_inputs_and_explicit_security_rebuild_publish(self):
        output, _ = self.select("0.1.1", [self.previous], fingerprint="d" * 64)
        self.assertIn("build=true", output)
        output, _ = self.select("0.1.1", [self.previous], force=True)
        self.assertIn("build=true", output)

    def test_retry_never_rebuilds_or_overwrites_a_published_version_even_with_force(self):
        output, manifest = self.select("0.1.0", [self.previous], force=True)
        self.assertIn("build=false", output)
        self.assertIn("publish=true", output)
        self.assertEqual(manifest, self.manifest)

    def test_draft_with_metadata_reuses_its_image_and_empty_draft_can_resume(self):
        draft = {**self.previous, "draft": True}
        output, manifest = self.select("0.1.0", [draft])
        self.assertIn("build=false", output)
        self.assertEqual(manifest, self.manifest)
        output, manifest = self.select("0.1.0", [{**draft, "assets": []}])
        self.assertIn("build=true", output)
        self.assertIsNone(manifest)

    def test_versions_are_strict_semver_and_releases_cannot_go_backwards(self):
        for tag in ["relay-v0.1.0-rc.1", "relay-v01.1.0", "0.1.0", "relay-v0.1.0;true"]:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release.tag_order(tag)
        with patch.object(release, "releases", return_value=[self.previous]), self.assertRaises(ValueError):
            release.release_state("0.0.9")

    def test_invalid_manifest_and_other_registry_are_rejected(self):
        release.validate_manifest(self.manifest, "relay-v0.1.0")
        for field, value in [("schema", 2), ("image", "ghcr.io/other/image"), ("digest", "latest"),
                             ("revision", "main"), ("version", "0.1.1")]:
            with self.subTest(field=field), self.assertRaises(ValueError):
                release.validate_manifest({**self.manifest, field: value}, "relay-v0.1.0")

    def test_non_main_missing_ci_and_tag_at_another_commit_fail_closed(self):
        with patch.dict(os.environ, {"GITHUB_REF": "refs/heads/feature"}), self.assertRaises(ValueError):
            release.require_source("0.1.0")
        with patch.object(release, "run", return_value="a" * 40), \
                patch.object(release, "gh", return_value={"workflow_runs": []}), self.assertRaises(ValueError):
            release.require_source("0.1.0")
        with patch.object(release, "run", return_value="wrong"), \
                patch.object(release, "gh", return_value={"workflow_runs": [{"head_branch": "main", "head_sha": "a" * 40}]}), \
                self.assertRaises(ValueError):
            release.require_source("0.1.0", "a" * 40)

    def test_published_retries_are_read_only(self):
        with patch.object(release, "require_source"), \
                patch.object(release, "input_hash", return_value="b" * 64), \
                patch.object(release, "image_digest", return_value=self.manifest["digest"]), \
                patch.object(release, "releases", return_value=[self.previous]), \
                patch.object(release, "load_manifest", return_value=self.manifest), \
                patch.object(release, "run") as commands:
            release.publish(self.manifest)
        commands.assert_not_called()

    def test_image_record_binds_the_version_to_tested_source_and_digest(self):
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(release, "require_source", return_value="a" * 40), \
                patch.object(release, "input_hash", return_value="b" * 64), \
                patch.object(release, "image_digest", return_value=self.manifest["digest"]):
            path = Path(directory) / "manifest.json"
            release.record("0.1.0", self.manifest["digest"], path)
            recorded = json.loads(path.read_text())
            self.assertEqual({key: recorded[key] for key in self.manifest}, self.manifest)
            self.assertTrue(recorded["build_url"].endswith("/actions/runs/123"))

    def test_changed_registry_digest_cannot_be_published(self):
        with patch.object(release, "require_source"), \
                patch.object(release, "input_hash", return_value="b" * 64), \
                patch.object(release, "image_digest", return_value="sha256:" + "d" * 64), \
                patch.object(release, "run") as commands, self.assertRaises(ValueError):
            release.publish(self.manifest)
        commands.assert_not_called()

    def test_upload_failure_leaves_a_recoverable_draft_and_retry_publishes_same_digest(self):
        def fail_upload(*args):
            if args[:3] == ("gh", "release", "upload"):
                raise subprocess.CalledProcessError(1, args)
            return ""
        with patch.object(release, "require_source"), \
                patch.object(release, "input_hash", return_value="b" * 64), \
                patch.object(release, "image_digest", return_value=self.manifest["digest"]), \
                patch.object(release, "releases", return_value=[]), \
                patch.object(release, "run", side_effect=fail_upload) as commands, self.assertRaises(subprocess.CalledProcessError):
            release.publish(self.manifest)
        self.assertFalse(any(call.args[:3] == ("gh", "release", "edit") for call in commands.call_args_list))
        with patch.object(release, "require_source"), \
                patch.object(release, "input_hash", return_value="b" * 64), \
                patch.object(release, "image_digest", return_value=self.manifest["digest"]), \
                patch.object(release, "releases", return_value=[{**self.previous, "draft": True}]), \
                patch.object(release, "load_manifest", return_value=self.manifest), \
                patch.object(release, "run", return_value="") as commands:
            release.publish(self.manifest)
        self.assertFalse(any(call.args[:3] == ("gh", "release", "create") for call in commands.call_args_list))
        self.assertTrue(any(call.args[:3] == ("gh", "release", "edit") for call in commands.call_args_list))


if __name__ == "__main__":
    unittest.main()
