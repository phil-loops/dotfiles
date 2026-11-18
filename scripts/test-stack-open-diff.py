#!/usr/bin/env python3
"""Exercise Helix checkout reuse in disposable repositories, without launching an editor."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class DiffCheckout(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="helix-diff-", dir="/private/tmp")
        self.root = Path(self.tmp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "test")
        self.git("config", "user.email", "test@example.com")
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "core.hooksPath", str(self.repo / ".git/hooks"))
        (self.repo / "a.ts").write_text("one\ntwo\n")
        (self.repo / "node_modules").mkdir()
        (self.repo / ".gen").mkdir()
        self.git("add", "a.ts")
        self.git("commit", "-qm", "base")
        self.base = self.git("rev-parse", "HEAD")
        self.git("checkout", "-qb", "edit")
        (self.repo / "a.ts").write_text("one\ntwo\nthree\n")
        self.git("commit", "-qam", "feat: add three")
        self.tip = self.git("rev-parse", "HEAD")
        self.git("checkout", "-q", "main")
        self.scripts = self.root / "scripts"
        self.scripts.mkdir()
        shutil.copy2(Path(__file__).with_name("stack-open"), self.scripts / "stack-open")
        self.log = self.root / "preparation.log"
        for name, body in {
            "stack-donor": 'printf "%s\\n" "$TEST_REPO"',
            "seed-gen": 'printf "seed\\n" >> "$TEST_PREPARATION_LOG"\n[ -e "$1/.gen" ] || ln -s "$TEST_REPO/.gen" "$1/.gen"',
            "helix-tsgo-stamp": 'printf "stamp\\n" >> "$TEST_PREPARATION_LOG"',
        }.items():
            script = self.scripts / name
            script.write_text("#!/bin/sh\n" + body + "\n")
            script.chmod(0o755)
        self.env = dict(os.environ, STACK_OPEN_DIR=str(self.root / "scratch"), STACK_OPEN_NO_REAP="1",
                        STACK_OPEN_NO_GEN_SYNC="1", TEST_REPO=str(self.repo), TEST_PREPARATION_LOG=str(self.log))

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args, repo=None):
        return subprocess.run(["git", "-C", str(repo or self.repo), *args], capture_output=True,
                              text=True, check=True).stdout.strip()

    def checkout(self):
        result = subprocess.run([str(self.scripts / "stack-open"), "--diff-path", "edit"],
                                cwd=self.repo, env=self.env, capture_output=True, text=True, check=True)
        return Path(result.stdout.strip())

    def test_reopening_keeps_edits_and_skips_repeated_preparation(self):
        directory = self.checkout()
        (directory / "a.ts").write_text("one\ntwo\nTHREE\n")
        self.log.write_text("")
        self.assertEqual(self.checkout(), directory)
        self.assertEqual(self.log.read_text(), "")
        self.assertEqual((directory / "a.ts").read_text(), "one\ntwo\nTHREE\n")
        self.assertEqual(self.git("rev-parse", "HEAD", repo=directory), self.base)

    def test_a_moved_branch_refreshes_the_checkout(self):
        directory = self.checkout()
        new_tip = self.git("commit-tree", "edit^{tree}", "-p", self.tip, "-m", "follow up")
        self.git("update-ref", "refs/heads/edit", new_tip, self.tip)
        self.log.write_text("")
        self.assertEqual(self.checkout(), directory)
        self.assertIn("seed", self.log.read_text())
        gitdir = Path(self.git("rev-parse", "--absolute-git-dir", repo=directory))
        self.assertEqual((gitdir / "stack-open-diff-base").read_text().strip(), f"{self.base} {new_tip}")

    def test_missing_dependencies_are_prepared_again(self):
        directory = self.checkout()
        (directory / "node_modules").unlink()
        self.log.write_text("")
        self.assertEqual(self.checkout(), directory)
        self.assertTrue((directory / "node_modules").is_dir())
        self.assertIn("seed", self.log.read_text())

    def test_a_changed_parent_does_not_reuse_the_old_diff(self):
        directory = self.checkout()
        self.git("reset", "--hard", self.tip)
        reopened = self.checkout()
        self.assertNotEqual(reopened, directory)
        self.assertEqual(self.git("rev-parse", "HEAD", repo=reopened), self.tip)


if __name__ == "__main__":
    unittest.main()
