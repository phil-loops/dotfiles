"""Safety and outbox tests. Never connects to the desktop or any chat."""
from pathlib import Path
import json
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import codex_say as bridge


TARGET = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"


class FakeIpc:
    attempts = []
    failure = None
    preflight_failure = False

    def __init__(self, path):
        self.path = path

    def prepare(self, target):
        if self.preflight_failure:
            raise ConnectionError("Read-only preflight failed")
        return "fixture-owner"

    def deliver(self, target, request, owner):
        self.attempts.append((target, request, owner))
        if self.failure:
            raise self.failure
        return {"result": {"result": {"turn": {"id": "fixture-turn"}}}}

    def close(self):
        pass


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.config = {"schema_version": 1, "state_dir": self.temp.name,
                       "ipc_socket": "/fixture/no-live-socket", "senders": {"claude": {"label": "Claude Code / Opus"}},
                       "targets": {"test": {"host_id": "local", "thread_id": TARGET, "fixture_only": True}}}
        FakeIpc.attempts, FakeIpc.failure, FakeIpc.preflight_failure = [], None, False
        self.pin = patch.object(bridge, "check_build")
        self.pin.start()

    def tearDown(self):
        self.pin.stop()
        self.temp.cleanup()

    def send(self, **changes):
        args = {"config": self.config, "config_dir": Path(self.temp.name), "target_value": "test",
                "sender_id": "claude", "source_session": "fixture-session", "message_id": "one",
                "body": "Quoted test data, never Phil's words.", "fixture": True, "ipc_factory": FakeIpc}
        args.update(changes)
        return bridge.send(**args)

    def test_attributed_tool_output_and_persistent_dedup(self):
        first = self.send()
        repeat = self.send()
        self.assertEqual(first["state"], "accepted")
        self.assertTrue(repeat["deduplicated"])
        self.assertEqual(len(FakeIpc.attempts), 1)
        request = FakeIpc.attempts[0][1]
        self.assertEqual(request["input"], [])
        self.assertEqual(request["toolOutput"]["namespace"], "external_agents")
        self.assertIn("Claude Code / Opus (synthetic test fixture)", request["toolOutput"]["output"])
        self.assertNotIn("model", request)
        self.assertNotIn("sandboxPolicy", request)

    def test_changed_content_or_attribution_rejected(self):
        self.send()
        with self.assertRaises(bridge.BridgeError):
            self.send(body="Changed content")
        self.config["senders"]["claude"]["label"] = "Different author"
        with self.assertRaises(bridge.BridgeError):
            self.send()
        self.assertEqual(len(FakeIpc.attempts), 1)

    def test_unknown_delivery_is_never_automatically_retried(self):
        FakeIpc.failure = TimeoutError("Acknowledgement lost")
        with self.assertRaises(bridge.DeliveryUnknown):
            self.send()
        result = self.send()
        self.assertEqual(result["state"], "unknown")
        self.assertTrue(result["deduplicated"])
        self.assertEqual(len(FakeIpc.attempts), 1)

    def test_preflight_failure_can_retry_without_duplicate_mutation(self):
        FakeIpc.preflight_failure = True
        with self.assertRaises(bridge.BridgeError):
            self.send()
        self.assertEqual(FakeIpc.attempts, [])
        FakeIpc.preflight_failure = False
        self.assertEqual(self.send()["state"], "accepted")
        self.assertEqual(len(FakeIpc.attempts), 1)

    def test_unconfigured_target_and_sender_and_nonfixture_refused(self):
        for changes in [{"target_value": "detector-research"}, {"target_value": "00000000-0000-0000-0000-000000000000"},
                        {"sender_id": "Phil"}, {"fixture": False}]:
            with self.subTest(changes=changes), self.assertRaises(bridge.BridgeError):
                self.send(**changes)
        self.assertEqual(FakeIpc.attempts, [])

    def test_dry_run_has_no_connection_or_ledger(self):
        result = self.send(dry_run=True)
        self.assertTrue(result["dry_run"])
        self.assertEqual(FakeIpc.attempts, [])
        self.assertFalse((Path(self.temp.name) / "outbox.sqlite3").exists())

    def test_private_ipc_has_no_interrupt_or_draft_methods(self):
        self.assertEqual(set(bridge.METHODS), {"initialize", "thread-owner-discovery",
                                             "thread-follower-read-model-settings", "thread-follower-start-turn"})

    def test_test_fixtures_are_forbidden_for_production_targets(self):
        self.config["targets"]["production"] = {"host_id": "local", "thread_id": TARGET, "allow_fixtures": False}
        with self.assertRaises(bridge.BridgeError):
            self.send(target_value="production")
        self.assertEqual(FakeIpc.attempts, [])

    def test_cli_content_id_is_stable_across_retries(self):
        config = Path(self.temp.name) / "config.json"
        config.write_text(json.dumps(self.config))
        command = [sys.executable, str(Path(bridge.__file__).absolute()), "test", "--config", str(config),
                   "--sender", "claude", "--source-session", "fixture-session", "--fixture", "--dry-run", "--message"]
        def request(body):
            result = subprocess.run(command + [body], text=True, capture_output=True, check=True)
            return json.loads(result.stdout)["request"]
        first, repeated, changed = request("one"), request("one"), request("two")
        self.assertEqual(first, repeated)
        self.assertNotEqual(first["clientUserMessageId"], changed["clientUserMessageId"])
        self.assertFalse((Path(self.temp.name) / "outbox.sqlite3").exists())


class VersionGuardTests(unittest.TestCase):
    def test_desktop_update_requires_revalidation(self):
        with tempfile.TemporaryDirectory() as temp:
            app = Path(temp) / "App.app"
            (app / "Contents").mkdir(parents=True)
            with (app / "Contents/Info.plist").open("wb") as output:
                plistlib.dump({"CFBundleVersion": "new-build", "CFBundleShortVersionString": "new-version"}, output)
            with self.assertRaises(bridge.BridgeError):
                bridge.check_build({"desktop": {"app_path": str(app), "version": "old-version", "build": "old-build"}})


if __name__ == "__main__":
    unittest.main()
