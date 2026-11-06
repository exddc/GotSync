import importlib.util
import os
import unittest
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("relay_deploy", Path(__file__).parents[1] / "relay-deploy.py")
deploy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(deploy)


class DeploymentTests(unittest.TestCase):
    def setUp(self):
        environment = patch.dict(os.environ, {
            "GITHUB_REPOSITORY": "exddc/GotSync", "COOLIFY_APPLICATION_UUID": "relayuuid",
        })
        environment.start()
        self.addCleanup(environment.stop)
        self.manifest = {
            "schema": 1, "version": "0.1.0", "revision": "a" * 40,
            "inputs_sha256": "b" * 64, "image": "ghcr.io/exddc/gotsync-relay",
            "digest": "sha256:" + "c" * 64,
        }
        self.application = {"build_pack": "dockercompose", "git_repository": "exddc/GotSync",
                            "base_directory": "/server/deploy/traefik"}

    def test_prerelease_versions_cannot_touch_production(self):
        with patch.object(deploy, "api") as api, self.assertRaises(ValueError):
            deploy.deploy({**self.manifest, "version": "0.1.0-rc.1"})
        api.assert_not_called()

    def test_wrong_application_cannot_be_modified(self):
        with patch.object(deploy, "api", return_value={**self.application, "git_repository": "other/repo"}) as api, \
                self.assertRaises(ValueError):
            deploy.deploy(self.manifest)
        self.assertEqual(api.call_count, 1)

    def test_pin_image_and_source_before_deployment_and_wait_for_success(self):
        calls = []
        def api(method, path, body=None):
            calls.append((method, path, body))
            if path.endswith("/envs") and method == "GET":
                return [{"key": "GOTSYNC_RELAY_IMAGE", "uuid": "envuuid", "is_preview": False}]
            if path == "/applications/relayuuid" and method == "GET":
                return self.application
            if path == "/deploy":
                return {"deployments": [{"deployment_uuid": "deploymentuuid"}]}
            if path == "/deployments/deploymentuuid":
                return {"status": "finished"}
            return {}
        with patch.object(deploy, "api", side_effect=api):
            deploy.deploy(self.manifest)
        self.assertEqual(calls[2][0], "PATCH")
        self.assertEqual(calls[2][2]["value"], self.manifest["image"] + "@" + self.manifest["digest"])
        self.assertEqual(calls[3][2], {
            "git_commit_sha": "a" * 40, "is_auto_deploy_enabled": False,
            "docker_compose_custom_start_command": "docker compose --project-name relayuuid up -d --wait --wait-timeout 120",
        })
        self.assertEqual(calls[4][:2], ("POST", "/deploy"))

    def test_failed_deployment_is_not_reported_as_success(self):
        with patch.object(deploy, "api", side_effect=[self.application, [], {}, {},
                          {"deployments": [{"deployment_uuid": "d"}]}, {"status": "failed"}]), \
                self.assertRaises(RuntimeError):
            deploy.deploy(self.manifest)


if __name__ == "__main__":
    unittest.main()
