#!/usr/bin/env python3
"""Tests for scripts/learning.py — the concept graph's derivations. Run: python3 scripts/test-learning.py"""
import json
import os
import sys
import tempfile
import unittest

os.environ["LEARNING_MEMORY"] = "0"
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import learning  # noqa: E402


def ev(g, concept, level="predict", credit="unaided", outcome="hit", at="2026-10-01", **extra):
    return learning.add_evidence(g, {"concept": concept, "level": level, "credit": credit, "outcome": outcome,
                                     "at": at, **extra})


def graph():
    g = learning._empty()
    learning.upsert_topic(g, {"id": "locks", "title": "Locks", "stages": [
        {"name": "why", "concepts": [{"id": "lock-ttl", "statement": "a lock expires"},
                                     {"id": "lease-renewal", "builds_on": ["lock-ttl"]}]}]})
    learning.upsert_topic(g, {"id": "cursors", "title": "Cursors", "stages": [
        {"name": "readers", "concepts": [{"id": "bookmark-atomic", "analogs": ["lease-renewal"]},
                                         {"id": "safety-lag", "builds_on": ["commit-order"]}]}]})
    return g


class Mastery(unittest.TestCase):
    def test_once_is_not_held(self):
        g = graph()
        ev(g, "lock-ttl", at="2026-10-01")
        m = learning.mastery(g, "lock-ttl", today="2026-10-01")
        self.assertEqual((m["depth"], m["held"]), (1, 0))
        ev(g, "lock-ttl", at="2026-10-01")           # same day again: still once
        self.assertEqual(learning.mastery(g, "lock-ttl", today="2026-10-01")["held"], 0)
        ev(g, "lock-ttl", at="2026-10-03")           # a second day: held
        m = learning.mastery(g, "lock-ttl", today="2026-10-03")
        self.assertEqual((m["depth"], m["held"]), (1, 1))

    def test_held_level_is_two_days_at_that_level(self):
        g = graph()
        ev(g, "lock-ttl", level="explain", at="2026-10-01")
        ev(g, "lock-ttl", level="predict", at="2026-10-05")
        m = learning.mastery(g, "lock-ttl", today="2026-10-05")
        self.assertEqual((m["level"], m["held_level"]), ("explain", "predict"))

    def test_once_becomes_due_after_the_base_gap(self):
        g = graph()
        ev(g, "lock-ttl", level="explain", at="2026-10-01")
        for day in ("2026-10-01", "2026-10-04"):
            m = learning.mastery(g, "lock-ttl", today=day)
            self.assertFalse(m["due"], day)
            self.assertEqual(m["spacing"], learning.BASE_SPACING_DAYS)   # depth doesn't stretch a once-only gap
        m = learning.mastery(g, "lock-ttl", today="2026-10-05")
        self.assertTrue(m["due"])
        self.assertIn("second day", m["reason"])

    def test_held_doubles_spacing(self):
        g = graph()
        ev(g, "lock-ttl", at="2026-10-01")
        ev(g, "lock-ttl", at="2026-10-05")
        m = learning.mastery(g, "lock-ttl", today="2026-10-12")
        self.assertFalse(m["due"])
        self.assertEqual(m["spacing"], 8)
        self.assertTrue(learning.mastery(g, "lock-ttl", today="2026-10-20")["due"])

    def test_confident_miss_outranks_everything(self):
        g = graph()
        ev(g, "lock-ttl", outcome="miss", note="thought renewing resets the TTL", at="2026-10-01")
        ev(g, "lease-renewal", outcome="miss", note="…", confidence="high", contrast="same lease, renew late once", at="2026-10-01")
        ev(g, "bookmark-atomic", credit="handed", at="2026-10-01")
        st = learning.state(g, today="2026-10-02")
        self.assertEqual(st["due"][:3], ["lease-renewal", "lock-ttl", "bookmark-atomic"])
        m = st["concepts"]["lease-renewal"]["mastery"]
        self.assertEqual((m["miss_confidence"], m["contrast"], m["overconfident"]), ("high", "same lease, renew late once", 1))

    def test_miss_clears_on_unaided_hit_at_level(self):
        g = graph()
        ev(g, "lock-ttl", level="explain", outcome="miss", at="2026-10-01")
        ev(g, "lock-ttl", level="predict", at="2026-10-02")        # below the missed level: still open
        self.assertTrue(learning.mastery(g, "lock-ttl", today="2026-10-02")["open_miss"])
        ev(g, "lock-ttl", level="explain", at="2026-10-03")
        m = learning.mastery(g, "lock-ttl", today="2026-10-03")
        self.assertFalse(m["open_miss"])
        self.assertEqual(m["corrected"], 1)


class Graph(unittest.TestCase):
    def test_blocked_by_and_gaps(self):
        g = graph()
        st = learning.state(g, today="2026-10-01")
        self.assertEqual(st["concepts"]["lease-renewal"]["blocked_by"], ["lock-ttl"])
        self.assertEqual(learning.gaps(g, "cursors", today="2026-10-01"), [{"concept": "commit-order", "blocks": "safety-lag"}])
        ev(g, "lock-ttl", at="2026-10-01")
        self.assertEqual(learning.state(g, today="2026-10-01")["concepts"]["lease-renewal"]["blocked_by"], [])
        ev(g, "lock-ttl", credit="scaffolded", at="2026-10-01")   # help never unblocks

    def test_opener_is_a_due_neighbor(self):
        g = graph()
        ev(g, "lease-renewal", at="2026-09-01")       # once, long ago → due; analog of bookmark-atomic
        ev(g, "lock-ttl", at="2026-09-01")            # due too, but not a neighbor of cursors
        op = learning.opener(g, "cursors", today="2026-10-01")
        self.assertEqual([o["id"] for o in op], ["lease-renewal"])
        self.assertEqual(op[0]["neighbor_of"], ["bookmark-atomic"])

    def test_transfers_need_a_held_analog(self):
        g = graph()
        self.assertEqual(learning.transfers(g, "cursors"), [])
        ev(g, "lease-renewal", level="explain", at="2026-10-01")
        self.assertEqual(learning.transfers(g, "cursors"), [{"concept": "bookmark-atomic", "via": "lease-renewal", "setting": "locks"}])

    def test_unaided_transfer_hit_names_its_analog(self):
        g = graph()
        with self.assertRaises(learning.Invalid):
            ev(g, "bookmark-atomic", level="transfer")
        ev(g, "bookmark-atomic", level="transfer", via="lease-renewal")
        self.assertEqual(g["evidence"][-1]["via"], "lease-renewal")

    def test_progress_counts_held_and_shown(self):
        g = graph()
        ev(g, "lock-ttl", level="explain", at="2026-10-01")
        ev(g, "lease-renewal", level="explain", at="2026-10-01")
        ev(g, "lease-renewal", level="explain", at="2026-10-02")
        p = learning.state(g, today="2026-10-02")["topics"]["locks"]["progress"]
        self.assertEqual(p, {"held": 1, "shown": 2, "total": 2})

    def test_restate(self):
        g = graph()
        learning.restate(g, "lock-ttl", "  a lock that nobody renews dies on its own ")
        self.assertEqual(g["concepts"]["lock-ttl"]["statement_learner"], "a lock that nobody renews dies on its own")
        with self.assertRaises(learning.Invalid):
            learning.restate(g, "nope", "x")


class Blocks(unittest.TestCase):
    def test_new_fields_and_blocks(self):
        g = graph()
        text = """prose
```tutor-evidence
[{"concept": "lock-ttl", "level": "predict", "credit": "unaided", "outcome": "miss",
  "note": "said the lock lives forever", "confidence": "high", "rung": "invent",
  "contrast": "same lock, holder dies at t=5"}]
```
```tutor-restate
{"concept": "lock-ttl", "text": "a lock has to die on its own"}
```
```tutor-question
"what if the clock skews?"
```
"""
        topic, applied, errors = learning.apply_blocks(g, text, topic="locks")
        self.assertEqual(errors, [])
        self.assertEqual(applied, ["evidence lock-ttl", "restate lock-ttl", "question"])
        row = g["evidence"][-1]
        self.assertEqual((row["confidence"], row["rung"], row["contrast"]), ("high", "invent", "same lock, holder dies at t=5"))
        self.assertEqual(g["questions"][-1]["topic"], "locks")

    def test_bad_extras_are_errors_not_crashes(self):
        g = graph()
        _, applied, errors = learning.apply_blocks(g, '```tutor-evidence\n{"concept": "lock-ttl", "level": "predict", "confidence": "sure"}\n```')
        self.assertEqual(applied, [])
        self.assertIn("confidence", errors[0])

    def test_old_rows_without_extras_still_read(self):
        g = graph()
        g["evidence"].append({"id": "old", "concept": "lock-ttl", "level": "predict", "credit": "unaided",
                              "outcome": "hit", "note": "", "at": "2026-09-01", "topic": "", "session": ""})
        m = learning.mastery(g, "lock-ttl", today="2026-10-01")
        self.assertEqual((m["depth"], m["miss_confidence"], m["contrast"]), (1, "", ""))
        self.assertIn("lock-ttl", learning.digest(g, topic="locks"))

    def test_edit_evidence_extras(self):
        g = graph()
        eid = ev(g, "lock-ttl", outcome="miss", confidence="low")
        learning.edit_evidence(g, eid, {"confidence": "high", "note": "x"})
        self.assertEqual(g["evidence"][-1]["confidence"], "high")
        learning.edit_evidence(g, eid, {"confidence": ""})
        self.assertNotIn("confidence", g["evidence"][-1])


class RealGraph(unittest.TestCase):
    def test_digest_runs_on_the_real_graph(self):
        path = os.path.expanduser("~/.dotfiles/learning/graph.json")
        if not os.path.exists(path):
            self.skipTest("no real graph")
        g = learning.load(path)
        st = learning.state(g)
        text = learning.digest(g, topic=next(iter(g["topics"]), None))
        self.assertIn("### Due for a re-test", text)
        for tid in g["topics"]:
            learning.opener(g, tid), learning.transfers(g, tid), learning.gaps(g, tid)
        self.assertTrue(all("blocked_by" in c for c in st["concepts"].values()))


class Roundtrip(unittest.TestCase):
    def test_save_load(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "g.json")
            with learning.editing(path, sync_memory=False) as g:
                learning.upsert_topic(g, {"id": "t", "title": "T", "stages": [{"name": "s", "concepts": ["a"]}]})
                ev(g, "a", confidence="medium")
            g = learning.load(path)
            self.assertEqual(g["evidence"][0]["confidence"], "medium")
            json.dumps(learning.state(g))


if __name__ == "__main__":
    unittest.main(verbosity=1)
