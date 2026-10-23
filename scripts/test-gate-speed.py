#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import time
import unittest

HERE = Path(__file__).resolve().parent
fingerprint = runpy.run_path(str(HERE / "seed-gen-fingerprint"))["fingerprint"]
spec = importlib.util.spec_from_file_location("gate_queue", HERE / "srv/gate_queue.py")
queue = importlib.util.module_from_spec(spec)
spec.loader.exec_module(queue)


def git(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()


def write(repo, name, text):
    path = repo / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def repo_at(repo):
    repo.mkdir()
    git(repo, "init", "-q", "-b", "main")
    git(repo, "config", "user.name", "test")
    git(repo, "config", "user.email", "test@example.com")
    git(repo, "config", "commit.gpgsign", "false")
    write(repo, ".gitignore", "node_modules/\n.gen/\n")
    write(repo, "trpc/root.ts", "export { used } from '../lib/used';\n")
    write(repo, "lib/used.ts", "export const used = 1;\n")
    write(repo, "trpc/extra.ts", "export const extra = 1;\n")
    write(repo, "pages/unused.tsx", "export const page = 1;\n")
    write(repo, "typescript/tsconfig.trpc-types.json", "{}\n")
    write(repo, "package-lock.json", '{"packages":{}}\n')
    write(repo, "node_modules/typescript/package.json", '{"version":"7.0.2"}')
    write(repo, ".gen/trpc-types/trpc/root.d.ts", "old output\n")
    git(repo, "add", ".")
    git(repo, "commit", "-qm", "initial")


def graph(repo):
    write(repo, ".gen/trpc-types.tsbuildinfo", json.dumps({
        "fileNames": ["../trpc/root.ts", "../lib/used.ts"]}))


class FingerprintTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / "repo"
        repo_at(self.repo)
        graph(self.repo)
        self.key = fingerprint(self.repo)

    def test_reword_docs_and_unused_source_keep_key(self):
        git(self.repo, "commit", "--allow-empty", "-qm", "new message")
        write(self.repo, "README.md", "docs\n")
        write(self.repo, "pages/unused.tsx", "export const page = 2;\n")
        self.assertEqual(fingerprint(self.repo), self.key)

    def test_uncommitted_input_change_and_revert(self):
        original = (self.repo / "lib/used.ts").read_text()
        write(self.repo, "lib/used.ts", "export const used = 2;\n")
        self.assertNotEqual(fingerprint(self.repo), self.key)
        write(self.repo, "lib/used.ts", original)
        self.assertEqual(fingerprint(self.repo), self.key)

    def test_new_resolution_candidate_changes_key(self):
        write(self.repo, "lib/used/index.ts", "export const shadow = 1;\n")
        self.assertNotEqual(fingerprint(self.repo), self.key)

    def test_lock_config_compiler_and_dependency_changes(self):
        for name in ("package-lock.json", "typescript/tsconfig.trpc-types.json",
                     "node_modules/typescript/package.json"):
            with self.subTest(name=name):
                original = (self.repo / name).read_text()
                write(self.repo, name, original + " ")
                self.assertNotEqual(fingerprint(self.repo), self.key)
                write(self.repo, name, original)
        write(self.repo, "node_modules/dep/index.d.ts", "export const x: number;\n")
        data = json.loads((self.repo / ".gen/trpc-types.tsbuildinfo").read_text())
        data["fileNames"].append("../node_modules/dep/index.d.ts")
        write(self.repo, ".gen/trpc-types.tsbuildinfo", json.dumps(data))
        before = fingerprint(self.repo)
        write(self.repo, "node_modules/dep/index.d.ts", "export const x: string;\n")
        self.assertNotEqual(fingerprint(self.repo), before)

    def test_deleted_artifact_and_missing_graph_are_uncacheable(self):
        (self.repo / ".gen/trpc-types/trpc/root.d.ts").unlink()
        with self.assertRaises(ValueError):
            fingerprint(self.repo)
        (self.repo / ".gen/trpc-types.tsbuildinfo").unlink()
        with self.assertRaises(OSError):
            fingerprint(self.repo)


class SeedTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / "repo"
        repo_at(self.repo)
        self.log = Path(self.temp.name) / "compiler.log"
        self.env = dict(os.environ, GATE_TEST_LOG=str(self.log))
        write(self.repo, "node_modules/typescript/bin/tsc", r'''
const fs = require('node:fs');
fs.appendFileSync(process.env.GATE_TEST_LOG, 'compile\n');
fs.mkdirSync('.gen/trpc-types/trpc', {recursive:true});
fs.writeFileSync('.gen/trpc-types/trpc/root.d.ts', fs.readFileSync('lib/used.ts'));
fs.writeFileSync('.gen/trpc-types/trpc/extra.d.ts', 'extra');
fs.writeFileSync('.gen/trpc-types.tsbuildinfo', JSON.stringify({fileNames:['../trpc/root.ts','../lib/used.ts','../trpc/extra.ts']}));
''')

    def sync(self, repo=None):
        result = subprocess.run([str(HERE / "seed-gen"), "--sync", str(repo or self.repo)],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def count(self):
        return len(self.log.read_text().splitlines())

    def test_sync_reuses_output_across_unrelated_commits_and_rebuilds_inputs(self):
        self.sync()
        self.assertEqual(self.count(), 1)
        self.assertEqual(self.sync(), "")
        write(self.repo, "README.md", "docs")
        git(self.repo, "add", "README.md")
        git(self.repo, "commit", "-qm", "docs")
        self.assertEqual(self.sync(), "")
        git(self.repo, "commit", "--allow-empty", "-qm", "reword-like history change")
        self.assertEqual(self.sync(), "")
        write(self.repo, "lib/used.ts", "export const used = 2;\n")
        self.sync()
        self.assertEqual(self.count(), 2)
        self.assertEqual(self.sync(), "")
        (self.repo / ".gen/trpc-types/trpc/extra.d.ts").unlink()
        self.sync()
        self.assertEqual(self.count(), 3)
        self.assertTrue((self.repo / ".gen/trpc-types/trpc/extra.d.ts").exists())

    def test_sync_prunes_outputs_whose_source_left_the_graph(self):
        self.sync()
        write(self.repo, ".gen/trpc-types/lib/gone.d.ts", "from another commit")
        write(self.repo, ".gen/trpc-types/lib/gone.d.ts.map", "{}")
        write(self.repo, "lib/used.ts", "export const used = 2;\n")
        self.sync()
        self.assertFalse((self.repo / ".gen/trpc-types/lib").exists())
        self.assertTrue((self.repo / ".gen/trpc-types/trpc/extra.d.ts").exists())
        self.assertEqual(self.sync(), "")

    def test_borrowed_types_reuse_and_divergence_stays_private(self):
        self.sync()
        donor_key = (self.repo / ".gen/.seed-gen-inputs").read_text()
        sibling = Path(self.temp.name) / "sibling"
        git(self.repo, "worktree", "add", "-qb", "child", str(sibling))
        (sibling / "node_modules").symlink_to(self.repo / "node_modules")
        (sibling / ".gen").symlink_to(self.repo / ".gen")
        self.assertEqual(self.sync(sibling), "")
        self.assertEqual(self.count(), 1)
        write(sibling, "lib/used.ts", "export const used = 3;\n")
        self.sync(sibling)
        self.assertEqual(self.count(), 2)
        self.assertFalse((sibling / ".gen").is_symlink())
        self.assertEqual((self.repo / ".gen/.seed-gen-inputs").read_text(), donor_key)


class QueueTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        repo_at(self.repo)
        for name in ("a", "b", "clicked"):
            git(self.repo, "branch", name)
        self.queue = self.root / "queue"
        self.slot = self.queue / "slot1"
        self.slot.mkdir(parents=True)
        (self.slot / "pid").write_text(str(os.getpid()))
        self.log = self.root / "runs.log"
        self.procs = []
        self.addCleanup(self.stop)
        self.worker = self.root / "worker.py"
        self.worker.write_text('''import os, pathlib, sys, time
root = pathlib.Path(sys.argv[1]); name = sys.argv[2]
fd = os.open(root / 'active', os.O_CREAT | os.O_EXCL | os.O_WRONLY)
os.close(fd)
with (root / 'runs.log').open('a') as f: f.write(name + '\\n')
time.sleep(0.05)
(root / 'active').unlink()
''')

    def stop(self):
        for proc in self.procs:
            if proc.poll() is None:
                proc.terminate()
            proc.communicate(timeout=10)

    def wait_for(self, condition):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if condition():
                return
            time.sleep(0.02)
        self.fail("queue condition timed out")

    def start(self, name, priority="background"):
        progress = self.root / (name + ".jsonl")
        command = [str(HERE / "stack-gates-turn"), "--queue", str(self.queue),
                   "--branch", name, "--tree", git(self.repo, "rev-parse", name + "^{tree}"),
                   "--priority", priority, "--", sys.executable, str(self.worker),
                   str(self.root), name, "--progress", str(progress)]
        proc = subprocess.Popen(command, cwd=self.repo, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.procs.append(proc)
        request = self.queue / (progress.name + ".queue.json")
        self.wait_for(request.exists)
        return proc, request, progress

    def release(self):
        (self.slot / "pid").unlink()
        self.slot.rmdir()

    def finish(self):
        for proc in self.procs:
            out, err = proc.communicate(timeout=10)
            self.assertEqual(proc.returncode, 0, out + err)
        self.assertFalse(self.slot.exists())
        self.assertFalse(list(self.queue.glob("*.queue.json")))

    def test_clicked_request_precedes_background_fifo_without_overlap(self):
        self.start("a")
        self.start("b")
        self.start("clicked", "interactive")
        self.release()
        self.finish()
        self.assertEqual(self.log.read_text().splitlines(), ["clicked", "a", "b"])

    def test_existing_background_request_can_be_promoted(self):
        self.start("a")
        _, request, _ = self.start("b")
        queue.promote(request)
        self.release()
        self.finish()
        self.assertEqual(self.log.read_text().splitlines(), ["b", "a"])

    def test_obsolete_queued_tree_never_runs(self):
        _, _, progress = self.start("a")
        write(self.repo, "lib/used.ts", "export const used = 4;\n")
        git(self.repo, "add", "lib/used.ts")
        git(self.repo, "commit", "-qm", "changed inputs")
        git(self.repo, "branch", "-f", "a", "main")
        self.release()
        self.finish()
        self.assertFalse(self.log.exists())
        verdict = json.loads(progress.read_text().splitlines()[-1])
        self.assertFalse(verdict["ok"])
        self.assertIn("branch changed", verdict["gates"][0]["summary"])

    def test_promotion_before_registration_is_preserved(self):
        self.start("a")
        queue.promote(self.queue / "b.jsonl.queue.json")
        self.start("b")
        self.release()
        self.finish()
        self.assertEqual(self.log.read_text().splitlines(), ["b", "a"])

    def test_crashed_slot_owner_does_not_wedge_queue(self):
        proc = subprocess.Popen([sys.executable, "-c", "pass"])
        proc.wait()
        (self.slot / "pid").write_text(str(proc.pid))
        self.start("a")
        self.finish()
        self.assertEqual(self.log.read_text().splitlines(), ["a"])


if __name__ == "__main__":
    unittest.main()
