import json
import fcntl
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest

from helix_save_journal import Refused, SaveJournal


class AcceptedSaveTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="canopy-save-accept-")
        self.root = Path(self.temporary.name) / "session"
        SaveJournal.create(self.root, "before\n", "fixture-snapshot", "owner-a")
        self.journal = SaveJournal(self.root, "owner-a")

    def tearDown(self):
        if self.journal is not None:
            self.journal.close()
        self.temporary.cleanup()

    def payload(self, **changes):
        return {"generation": "owner-a", "operation": "save-a", "expectedRevision": 0,
                "documentVersion": 5, "uri": self.journal.state["uri"], "text": "after\n", "mode": "100644", **changes}

    def test_lost_response_replays_exact_original_payload_after_restart(self):
        payload = self.payload()
        receipt = self.journal.accept(payload)
        self.journal.close()
        self.journal = SaveJournal(self.root, "owner-a")
        self.assertEqual(self.journal.accept(payload), receipt)
        self.assertEqual(self.journal.state["revision"], 1)
        self.assertEqual(self.journal.snapshot(), (b"after\n", "100644"))
        self.assertEqual(self.journal.snapshot(0), (b"before\n", "100644"))

    def test_operation_reuse_cannot_change_bytes_mode_or_observed_revision(self):
        self.journal.accept(self.payload())
        for change in ({"text": "different"}, {"mode": "100755"}, {"expectedRevision": 1}):
            with self.subTest(change=change), self.assertRaises(Refused):
                self.journal.accept(self.payload(**change))
        self.assertEqual(self.journal.state["revision"], 1)

    def test_stale_scan_cannot_overwrite_direct_acceptance(self):
        stale_scan = self.payload(operation="scan", text="external scan\n")
        self.journal.accept(self.payload())
        with self.assertRaisesRegex(Refused, "stale"):
            self.journal.accept(stale_scan)
        self.assertEqual(self.journal.snapshot()[0], b"after\n")

    def test_live_lease_blocks_second_owner_and_old_generation_is_fenced_after_transfer(self):
        with self.assertRaisesRegex(Refused, "another editor"):
            SaveJournal(self.root, "owner-b")
        old_payload = self.payload()
        self.journal.close()
        self.journal = SaveJournal(self.root, "owner-b")
        with self.assertRaisesRegex(Refused, "another owner"):
            self.journal.accept(old_payload)
        self.assertEqual(self.journal.state["revision"], 0)
        self.assertEqual(self.journal.accept(self.payload(generation="owner-b"))["revision"], 1)

    def test_editor_keeps_projection_owned_when_companion_exits(self):
        self.journal.close()
        self.journal = None
        editor_fd = os.open(self.root / "editor.lock", os.O_RDWR)
        try:
            fcntl.flock(editor_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            helper = SaveJournal(self.root, "owner-a", projection_fd=editor_fd)
            helper.close()
            with self.assertRaisesRegex(Refused, "another editor"):
                SaveJournal(self.root, "owner-b")
        finally:
            os.close(editor_fd)
        self.journal = SaveJournal(self.root, "owner-b")

    def test_projection_mismatch_is_preserved_and_blocks_readiness_and_acceptance(self):
        self.journal.file.write_text("unreported writer\n")
        with self.assertRaisesRegex(Refused, "reconciliation"):
            self.journal.ready()
        with self.assertRaisesRegex(Refused, "opaque"):
            self.journal.accept(self.payload())
        self.assertEqual(self.journal.file.read_text(), "unreported writer\n")
        self.assertEqual(self.journal.snapshot()[0], b"before\n")

    def test_accepted_versions_remain_immutable_during_later_edits(self):
        self.journal.accept(self.payload())
        self.journal.accept(self.payload(operation="next", expectedRevision=1, documentVersion=6, text="later\n"))
        self.assertEqual(self.journal.snapshot(1)[0], b"after\n")
        self.assertEqual(self.journal.snapshot(2)[0], b"later\n")

    def test_journal_or_lease_replacement_refuses_without_modifying_saved_bytes(self):
        (self.root / "bridge.lock").rename(self.root / "original.lock")
        (self.root / "bridge.lock").touch()
        with self.assertRaisesRegex(Refused, "replaced"):
            self.journal.accept(self.payload())
        self.assertEqual(self.journal.state["revision"], 0)

    def test_copying_a_journal_to_another_projection_does_not_rebind_it(self):
        self.journal.close()
        self.journal = None
        copied = self.root.with_name("copied")
        shutil.copytree(self.root, copied)
        with self.assertRaisesRegex(Refused, "another projection"):
            SaveJournal(copied, "owner-a")

    def test_process_death_preserves_atomic_acceptance_and_identical_retry(self):
        payload = self.payload()
        self.journal.close()
        self.journal = None
        worker = """
import json,os,signal,sys
from helix_save_journal import SaveJournal
def fault(phase):
    if phase == sys.argv[2]: os.kill(os.getpid(), signal.SIGKILL)
j=SaveJournal(sys.argv[1],'owner-a',fault=fault)
j.accept(json.loads(sys.argv[3]))
"""
        for phase, expected in (("before-commit", 0), ("after-commit", 1)):
            with self.subTest(phase=phase):
                result = subprocess.run([sys.executable, "-c", worker, str(self.root), phase, json.dumps(payload)],
                                        cwd=Path(__file__).parent, capture_output=True)
                self.assertEqual(result.returncode, -9, result.stderr.decode())
                self.journal = SaveJournal(self.root, "owner-a")
                self.assertEqual(self.journal.state["revision"], expected)
                receipt = self.journal.accept(payload)
                self.assertEqual(receipt["revision"], 1)
                self.assertEqual(self.journal.accept(payload), receipt)
                self.journal.close()
                self.journal = None
                if phase == "before-commit":
                    shutil.rmtree(self.root)
                    SaveJournal.create(self.root, "before\n", "fixture-snapshot", "owner-a")


if __name__ == "__main__":
    unittest.main()
