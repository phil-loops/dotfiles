"""Differential and process-death checks for both experimental draft backends."""
import os
from pathlib import Path
import random
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

from editor_drafts import Draft, Objects, Refused, fixture

BACKENDS = ("workspace", "hybrid", "objects")


class DraftOptions(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="canopy-draft-options-")
        self.root = Path(self.temporary.name)
        self.objects = fixture(self.root / "repo", 12)
        self.drafts = []

    def tearDown(self):
        for draft in self.drafts:
            draft.close()
        self.objects.close()
        self.temporary.cleanup()

    def draft(self, mode):
        draft = Draft.create(self.root / uuid.uuid4().hex, self.objects, mode, "refs/canopy-lab/fixture")
        self.drafts.append(draft)
        return draft

    def oracle(self, changes):
        directory = self.root / uuid.uuid4().hex
        self.objects.run("worktree", "add", "--detach", str(directory), "refs/canopy-lab/fixture")
        for path, value in changes.items():
            target = directory / path
            if target.exists() or target.is_symlink():
                target.unlink()
            if value is not None:
                mode, content = value
                target.parent.mkdir(parents=True, exist_ok=True)
                if mode == "120000":
                    target.symlink_to(os.fsdecode(content))
                else:
                    target.write_bytes(content)
                    target.chmod(0o755 if mode == "100755" else 0o644)
        environment = {**self.objects.env}
        subprocess.run(["git", "-C", str(directory), "add", "-A", "--", "."], env=environment, check=True, capture_output=True)
        return subprocess.check_output(["git", "-C", str(directory), "write-tree"], env=environment).decode().strip()

    def test_both_backends_match_git_for_edits_deletions_renames_modes_symlinks_and_binary(self):
        changes = {"edit.txt": ("100644", b"after\0binary\n"), "canopy-lab/helper.ts": None,
                   "moved helper.ts": ("100644", b"export const value = 'snapshot import';\n"),
                   "nested/space and\nnewline.txt": ("100755", b"#!/bin/sh\necho okay\n"), "link": ("120000", b"edit.txt")}
        expected = self.oracle(changes)
        for mode in BACKENDS:
            with self.subTest(mode=mode):
                draft = self.draft(mode)
                self.assertEqual(draft.mutate("edit", 0, changes), 1)
                receipt = draft.publish("save", 1)
                self.assertEqual(receipt["tree"], expected)
                self.assertEqual(draft.publish("save", 1), receipt)
                self.assertEqual(self.objects.text("rev-list", "--count", draft.meta["base"] + ".." + draft.meta["ref"]), "1")
                self.assertEqual(draft.read("edit.txt"), changes["edit.txt"])
                with self.assertRaises(FileNotFoundError):
                    draft.read("canopy-lab/helper.ts")

    def test_random_manifests_match_a_full_git_stage(self):
        randomizer = random.Random(7391)
        for _ in range(8):
            changes = {f"payload/0000/{index:06d}.txt": None if randomizer.randrange(4) == 0 else
                       (randomizer.choice(("100644", "100755")), randomizer.randbytes(randomizer.randrange(80)))
                       for index in randomizer.sample(range(12), 6)}
            expected = self.oracle(changes)
            for mode in BACKENDS:
                draft = self.draft(mode)
                draft.mutate("edit", 0, changes)
                self.assertEqual(draft.publish("save", 1)["tree"], expected)

    def test_repeated_mutations_are_idempotent_and_stale_or_changed_operations_are_refused(self):
        for mode in BACKENDS:
            draft = self.draft(mode)
            changes = {"edit.txt": ("100644", b"one\n")}
            self.assertEqual(draft.mutate("same", 0, changes), 1)
            self.assertEqual(draft.mutate("same", 0, changes), 1)
            for operation, version, body in (("same", 0, {"edit.txt": ("100644", b"other\n")}), ("late", 0, changes)):
                with self.assertRaises(Refused):
                    draft.mutate(operation, version, body)
            self.assertEqual(draft.version, 1)
            frozen = draft.freeze("save", 1)
            with self.assertRaises(Refused):
                draft.mutate("new", 1, changes)
            with self.assertRaises(Refused):
                draft.freeze("other", 1)
            self.assertEqual(draft.publish("save", 1)["commit_oid"], frozen["commit_oid"])

    def test_opaque_external_writers_block_publication(self):
        for mode in BACKENDS:
            draft = self.draft(mode)
            draft.project("edit.txt").write_text("an unreported external write\n")
            draft.invalidate()
            with self.assertRaises(Refused):
                draft.publish("save", 0)
            self.assertEqual(self.objects.text("rev-parse", draft.meta["ref"]), draft.meta["base"])

    def test_moved_ref_preserves_the_frozen_edit(self):
        for mode in BACKENDS:
            draft = self.draft(mode)
            draft.mutate("edit", 0, {"edit.txt": ("100644", b"frozen\n")})
            receipt = draft.freeze("save", 1)
            other = self.objects.text("commit-tree", draft.meta["tree"], "-p", draft.meta["base"], data=b"another writer\n")
            self.objects.run("update-ref", draft.meta["ref"], other, draft.meta["base"])
            with self.assertRaises(Refused):
                draft.publish("save", 1)
            self.assertEqual(draft.freeze("save", 1), receipt)
            self.assertEqual(self.objects.text("rev-parse", draft.meta["ref"]), other)

    def test_parent_and_child_paths_and_directory_operations_are_refused(self):
        for mode in BACKENDS:
            draft = self.draft(mode)
            for path in ("../escape", "/absolute", ".git/config", "a//b", "x\0y", "canopy-lab"):
                with self.assertRaises(Refused):
                    draft.mutate("bad", 0, {path: None})
            draft.mutate("overlap", 0, {"new": ("100644", b"a"), "new/child": ("100644", b"b")})
            with self.assertRaises(Refused):
                draft.publish("save", 1)

    def test_a_thin_projection_retains_full_snapshot_reads_without_materializing_imports(self):
        draft = self.draft("objects")
        main = draft.project("canopy-lab/main.ts")
        helper = main.with_name("helper.ts")
        self.assertFalse(helper.exists())
        self.assertIn(b"snapshot import", draft.read("canopy-lab/helper.ts")[1])
        self.assertEqual(sum(1 for path in (draft.root / "files").rglob("*") if path.is_file()), 1)
        main.unlink()
        main.symlink_to(self.root / "outside")
        with self.assertRaises(Refused):
            draft.project("canopy-lab/main.ts")

    def test_process_death_recovers_atomic_mutations_and_exactly_one_publication(self):
        worker = """
import os, signal, sys
from editor_drafts import Draft, Objects
objects = Objects(sys.argv[1])
def fault(phase):
    if phase == sys.argv[3]: os.kill(os.getpid(), signal.SIGKILL)
draft = Draft(sys.argv[2], objects, fault=fault)
draft.mutate('edit', 0, {'edit.txt': ('100644', b'after\\n')})
draft.publish('save', 1)
"""
        phases = ("content-hashed", "mutation-before-commit", "mutation-committed", "freeze-before-commit", "prepared", "ref-advanced", "committed")
        for mode in BACKENDS:
            for phase in phases:
                with self.subTest(mode=mode, phase=phase):
                    draft = self.draft(mode)
                    draft.close()
                    self.drafts.remove(draft)
                    result = subprocess.run([sys.executable, "-c", worker, str(self.objects.repo), str(draft.root), phase],
                                            env={**os.environ, "PYTHONPATH": str(Path(__file__).resolve().parent)}, capture_output=True, timeout=20)
                    self.assertEqual(result.returncode, -9, result.stderr.decode())
                    recovered = Draft(draft.root, self.objects)
                    self.drafts.append(recovered)
                    self.assertEqual(recovered.version, 0 if phase in phases[:2] else 1)
                    recovered.mutate("edit", 0, {"edit.txt": ("100644", b"after\n")})
                    receipt = recovered.publish("save", 1)
                    self.assertEqual(recovered.publish("save", 1), receipt)
                    self.assertEqual(self.objects.text("rev-list", "--count", recovered.meta["base"] + ".." + recovered.meta["ref"]), "1")
                    self.assertEqual(self.objects.read(receipt["tree"], "edit.txt")[1], b"after\n")

    def test_real_repositories_without_the_lab_marker_are_refused(self):
        with self.assertRaises((Refused, FileNotFoundError)):
            Objects(Path(__file__).resolve().parents[2])

    def test_concurrent_writers_accept_exactly_one_expected_revision(self):
        worker = """
import pathlib, sys, time
from editor_drafts import Draft, Objects, Refused
objects = Objects(sys.argv[1])
draft = Draft(sys.argv[2], objects)
root = pathlib.Path(sys.argv[2])
(root / ('ready-' + sys.argv[3])).touch()
while not (root / 'start').exists(): time.sleep(0.005)
try:
    draft.mutate(sys.argv[3], 0, {'edit.txt': ('100644', sys.argv[3].encode())})
except Refused:
    sys.exit(75)
finally:
    draft.close()
    objects.close()
"""
        for mode in BACKENDS:
            draft = self.draft(mode)
            processes = [subprocess.Popen([sys.executable, "-c", worker, str(self.objects.repo), str(draft.root), name],
                         env={**os.environ, "PYTHONPATH": str(Path(__file__).resolve().parent)}, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                         for name in ("first", "second")]
            try:
                until = time.monotonic() + 10
                while len(list(draft.root.glob("ready-*"))) != 2 and time.monotonic() < until:
                    time.sleep(0.01)
                self.assertEqual(len(list(draft.root.glob("ready-*"))), 2)
                (draft.root / "start").touch()
                for process in processes:
                    process.communicate(timeout=15)
                self.assertEqual(sorted(process.returncode for process in processes), [0, 75])
                self.assertEqual(draft.version, 1)
                self.assertEqual(draft.db.execute("SELECT COUNT(*) FROM operations").fetchone()[0], 1)
                self.assertIn(draft.read("edit.txt")[1], (b"first", b"second"))
            finally:
                for process in processes:
                    if process.poll() is None:
                        process.kill()
                    process.communicate()

    def test_pending_content_survives_git_pruning_before_freeze(self):
        for mode in BACKENDS:
            draft = self.draft(mode)
            content = (mode + " unanchored draft content").encode()
            draft.mutate("edit", 0, {"edit.txt": ("100644", content)})
            self.objects.run("prune", "--expire", "now")
            self.assertEqual(draft.read("edit.txt")[1], content)
            self.assertEqual(self.objects.read(draft.publish("save", 1)["tree"], "edit.txt")[1], content)

    def test_identical_commit_ids_in_another_repository_cannot_rebind_a_journal(self):
        other = fixture(self.root / "other-repo", 12)
        try:
            self.assertEqual(other.text("rev-parse", "refs/canopy-lab/fixture"), self.objects.text("rev-parse", "refs/canopy-lab/fixture"))
            for mode in BACKENDS:
                draft = self.draft(mode)
                with self.assertRaises(Refused):
                    Draft(draft.root, other)
        finally:
            other.close()

    def test_complete_deletion_produces_the_empty_tree_and_unchanged_writes_make_no_commit(self):
        paths = self.objects.run("ls-tree", "-r", "--name-only", "-z", "refs/canopy-lab/fixture").decode().strip("\0").split("\0")
        empty = self.objects.text("mktree", data=b"")
        for mode in BACKENDS:
            deleted = self.draft(mode)
            deleted.mutate("delete", 0, {path: None for path in paths})
            self.assertEqual(deleted.publish("save", 1)["tree"], empty)
            unchanged = self.draft(mode)
            unchanged.mutate("same", 0, {"edit.txt": ("100644", b"before\n")})
            self.assertEqual(unchanged.publish("save", 1)["commit_oid"], unchanged.meta["base"])

    def test_tree_publishers_never_construct_an_index_or_scan_the_filesystem(self):
        for mode in ("hybrid", "objects"):
            draft = self.draft(mode)
            self.objects.calls.clear()
            draft.mutate("write", 0, {"edit.txt": ("100644", b"after\n")})
            draft.publish("save", 1)
            self.assertFalse((draft.root / "publication-index").exists())
            self.assertFalse(any(call[0] in ("read-tree", "write-tree", "update-index", "status", "add", "diff-files") for call in self.objects.calls))

    def test_sha256_object_ids_work_for_all_backends(self):
        objects = fixture(self.root / "sha256", 2, object_format="sha256")
        try:
            for mode in BACKENDS:
                draft = Draft.create(self.root / uuid.uuid4().hex, objects, mode, "refs/canopy-lab/fixture")
                try:
                    self.assertEqual(len(draft.meta["base"]), 64)
                    draft.mutate("write", 0, {"edit.txt": None, "new/sub.txt": ("100755", b"sha256\n")})
                    receipt = draft.publish("save", 1)
                    self.assertEqual(len(receipt["commit_oid"]), 64)
                    self.assertEqual(objects.read(receipt["tree"], "new/sub.txt"), ("100755", b"sha256\n"))
                finally:
                    draft.close()
        finally:
            objects.close()

    def test_changed_journal_content_cannot_publish_under_the_original_identity(self):
        for mode in BACKENDS:
            draft = self.draft(mode)
            draft.mutate("edit", 0, {"edit.txt": ("100644", b"original journal bytes")})
            draft.db.execute("UPDATE mutations SET content=?", (b"changed bytes",))
            with self.assertRaises(Refused):
                draft.publish("save", 1)
            self.assertEqual(self.objects.text("rev-parse", draft.meta["ref"]), draft.meta["base"])

    def test_replacing_a_repository_at_the_same_path_does_not_rebind_a_draft(self):
        draft = self.draft("objects")
        self.objects.close()
        self.objects.repo.rename(self.root / "original-repo")
        replacement = fixture(self.root / "repo", 12)
        try:
            with self.assertRaises(Refused):
                Draft(draft.root, replacement)
            with self.assertRaises(Refused):
                draft.mutate("edit", 0, {"edit.txt": ("100644", b"do not rebind")})
            self.assertEqual(replacement.text("rev-parse", "refs/canopy-lab/fixture"), draft.meta["base"])
        finally:
            replacement.close()


if __name__ == "__main__":
    unittest.main()
