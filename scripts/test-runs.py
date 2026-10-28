#!/usr/bin/env python3
"""srv/runs.py against the real filesystem and real short processes."""
import importlib
import os
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


def fresh():
    """A runs module as a new server image would load it — nothing in memory, only the disk."""
    import srv.runs
    return importlib.reload(srv.runs)


def until(cond, timeout=5.0):
    t0 = time.time()
    while time.time() - t0 < timeout:
        if cond():
            return True
        time.sleep(0.02)
    return False


class Runs(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["CANOPY_RUNS"] = self.tmp.name
        self.runs = fresh()

    def tearDown(self):
        for r in self.runs.every("t"):
            if r.alive():
                r.stop()
        self.tmp.cleanup()

    def test_output_is_tailed_while_running_and_the_exit_code_lands(self):
        r = self.runs.start("t", "a", ["sh", "-c", "echo one; sleep 0.4; echo two; exit 3"], cwd="/")
        self.assertTrue(until(lambda: r.read("out.log")[0] == b"one\n"))
        self.assertTrue(r.alive())
        _, off = r.read("out.log")
        self.assertTrue(until(lambda: not r.alive()))
        self.assertEqual(r.read("out.log", off)[0], b"two\n")
        self.assertEqual(r.exit_code(), 3)

    def test_stderr_splits_when_asked(self):
        r = self.runs.start("t", "e", ["sh", "-c", "echo out; echo err >&2"], cwd="/", out="o", err="e")
        until(lambda: not r.alive())
        self.assertEqual(r.read("o")[0], b"out\n")
        self.assertEqual(r.read("e")[0], b"err\n")

    def test_a_stop_kills_the_group_and_says_so(self):
        r = self.runs.start("t", "s", ["sh", "-c", "sleep 30 & wait"], cwd="/")
        self.assertTrue(until(r.alive))
        r.stop()
        self.assertTrue(until(lambda: not r.alive()))
        self.assertTrue(r.marked("stopped"))
        self.assertIsNone(r.exit_code())

    def test_a_new_server_image_finds_a_live_run_from_disk(self):
        r = self.runs.start("t", "a/b c", ["sh", "-c", "sleep 0.5; echo done"], cwd="/", meta={"tab": "x"})
        other = fresh().find("t", "a/b c")
        self.assertEqual((other.pid, other.meta), (r.pid, {"tab": "x"}))
        self.assertTrue(other.alive())
        self.assertTrue(until(lambda: not other.alive()))
        self.assertEqual(other.exit_code(), 0)
        self.assertEqual(other.read("out.log")[0], b"done\n")

    def test_a_finished_child_is_reaped_not_seen_as_a_live_zombie(self):
        r = self.runs.start("t", "z", ["sh", "-c", "exit 0"], cwd="/")
        time.sleep(0.3)
        os.remove(r.path("exit"))   # as if the launcher died before writing it
        self.assertFalse(r.alive())

    def test_a_live_run_holds_its_key_and_a_finished_one_is_replaced(self):
        r = self.runs.start("t", "k", ["sleep", "5"], cwd="/")
        with self.assertRaises(self.runs.Busy):
            self.runs.start("t", "k", ["true"], cwd="/")
        r.stop()
        until(lambda: not r.alive())
        r2 = self.runs.start("t", "k", ["true"], cwd="/")
        self.assertNotEqual(r2.pid, r.pid)
        self.assertFalse(r2.marked("stopped"))

    def test_markers_are_once_only_records(self):
        r = self.runs.start("t", "m", ["true"], cwd="/")
        self.assertFalse(r.marked("applied"))
        r.mark("applied", '{"n": 1}')
        self.assertEqual(fresh().find("t", "m").marker("applied"), '{"n": 1}')

    def test_prune_drops_only_old_finished_runs(self):
        old = self.runs.start("t", "old", ["true"], cwd="/")
        live = self.runs.start("t", "live", ["sleep", "5"], cwd="/")
        until(lambda: not old.alive())
        self.runs.prune("t", older_than=-1)
        self.assertIsNone(self.runs.find("t", "old"))
        self.assertIsNotNone(self.runs.find("t", "live"))

    def test_a_dotted_key_stays_inside_its_kind(self):
        r = self.runs.start("t", "..", ["true"], cwd="/")
        self.assertEqual(os.path.dirname(r.dir), os.path.join(self.tmp.name, "t"))


if __name__ == "__main__":
    unittest.main()
