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
        ev(g, "lock-ttl", at="2026-10-03")           # a second day, too soon: still not retention
        self.assertEqual(learning.mastery(g, "lock-ttl", today="2026-10-03")["held"], 0)
        ev(g, "lock-ttl", at="2026-10-05")           # the base gap after the first: held
        m = learning.mastery(g, "lock-ttl", today="2026-10-05")
        self.assertEqual((m["depth"], m["held"]), (1, 1))

    def test_overdue_counts_from_when_it_came_due(self):
        g = graph()
        ev(g, "lock-ttl", at="2026-10-01")
        self.assertEqual(learning.mastery(g, "lock-ttl", today="2026-10-05")["overdue"], 0)
        self.assertEqual(learning.mastery(g, "lock-ttl", today="2026-10-15")["overdue"], 10)
        ev(g, "lease-renewal", outcome="miss", at="2026-10-01")
        self.assertEqual(learning.mastery(g, "lease-renewal", today="2026-10-08")["overdue"], 7)

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
        self.assertIn("makes it held", m["reason"])

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
        ev(g, "lease-renewal", level="explain", at="2026-10-05")
        p = learning.state(g, today="2026-10-05")["topics"]["locks"]["progress"]
        self.assertEqual(p, {"held": 1, "shown": 2, "total": 2})

    def test_restate(self):
        g = graph()
        learning.restate(g, "lock-ttl", "  a lock that nobody renews dies on its own ")
        self.assertEqual(g["concepts"]["lock-ttl"]["statement_learner"], "a lock that nobody renews dies on its own")
        with self.assertRaises(learning.Invalid):
            learning.restate(g, "nope", "x")


def system_graph():
    g = graph()
    learning.upsert_system(g, {"id": "locking", "title": "Locking", "summary": "who may run what", "standards": [
        {"id": "predict-expiry", "can_do": "Predict when a dead holder's lock frees", "concepts": ["lock-ttl", "lease-renewal"]},
        {"id": "judge-coordination", "can_do": "Judge whether a lock guards correctness or only saves work",
         "concepts": [{"id": "advisory-lock", "statement": "a lock that only saves work"}]}]})
    return g


class Systems(unittest.TestCase):
    def test_upsert_keeps_order_and_reuses_concepts(self):
        g = system_graph()
        self.assertEqual(g["systems"]["locking"]["standards"], ["predict-expiry", "judge-coordination"])
        self.assertEqual(g["concepts"]["advisory-lock"]["statement"], "a lock that only saves work")
        learning.upsert_system(g, {"id": "locking", "standards": [{"id": "predict-expiry"}]})   # no can_do, no concepts: kept
        self.assertEqual(g["standards"]["predict-expiry"]["concepts"], ["lock-ttl", "lease-renewal"])
        with self.assertRaises(learning.Invalid):
            learning.upsert_system(g, {"id": "other", "standards": [{"id": "predict-expiry", "can_do": "x"}]})
        with self.assertRaises(learning.Invalid):
            learning.upsert_system(g, {"id": "locking", "standards": [{"id": "new-one"}]})

    def test_standard_mastery_is_its_own_rows(self):
        g = system_graph()
        ev(g, "lock-ttl", at="2026-10-01")                       # concept row: coverage, not the standard's depth
        st = learning.state(g, today="2026-10-01")["standards"]["predict-expiry"]
        self.assertEqual((st["mastery"]["depth"], st["coverage"]), (0, {"held": 0, "shown": 1, "total": 2}))
        learning.add_evidence(g, {"standard": "predict-expiry", "level": "predict", "at": "2026-10-01"})
        learning.add_evidence(g, {"standard": "predict-expiry", "level": "predict", "at": "2026-10-05"})
        st = learning.state(g, today="2026-10-05")
        self.assertEqual(st["standards"]["predict-expiry"]["mastery"]["held"], 1)
        self.assertEqual(st["systems"]["locking"]["progress"], {"held": 1, "met": 1, "total": 2})
        self.assertEqual(learning.mastery(g, "lock-ttl", today="2026-10-03")["evidence"], 1)

    def test_evidence_needs_a_known_standard_or_a_concept(self):
        g = system_graph()
        with self.assertRaises(learning.Invalid):
            learning.add_evidence(g, {"level": "predict"})
        with self.assertRaises(learning.Invalid):
            learning.add_evidence(g, {"standard": "nope", "level": "predict"})
        with self.assertRaises(learning.Invalid):
            learning.add_evidence(g, {"concept": "lock-ttl", "level": "predict", "source": "slack"})

    def test_capture_stamps_chat_and_attaches_concepts(self):
        g = system_graph()
        applied = learning.capture(g, {"concepts": [{"id": "fencing-token", "statement": "s", "standard": "judge-coordination"}],
                                       "evidence": [{"concept": "fencing-token", "level": "explain", "credit": "handed"},
                                                    {"standard": "judge-coordination", "level": "critique", "credit": "scaffolded"}],
                                       "questions": ["what does group mean?"]}, session="s1")
        self.assertEqual(applied, ["concept fencing-token", "evidence fencing-token", "evidence judge-coordination", "question"])
        self.assertIn("fencing-token", g["standards"]["judge-coordination"]["concepts"])
        self.assertEqual({r["source"] for r in g["evidence"]}, {"chat"})
        self.assertEqual(g["evidence"][-1]["standard"], "judge-coordination")
        with self.assertRaises(learning.Invalid):
            learning.capture(g, {"concepts": [{"id": "x", "standard": "nope"}]})

    def test_system_digest(self):
        g = system_graph()
        learning.add_evidence(g, {"standard": "predict-expiry", "level": "predict", "outcome": "miss",
                                  "note": "counted from the renewal", "at": "2026-10-01"})
        text = learning.digest(g, system="locking", today="2026-10-02")
        self.assertIn("### Active system: Locking [locking] — 0 held / 0 met / 2 standards", text)
        self.assertIn("OPEN MISS: counted from the renewal", text)
        self.assertIn("**Never assessed** (no standard-tagged row yet): judge-coordination", text)
        self.assertIn("  - lock-ttl", text)


class Retest(unittest.TestCase):
    def test_top_due_skips_what_was_tested_today(self):
        g = system_graph()
        ev(g, "lock-ttl", outcome="miss", note="thought it lives forever", contrast="holder dies at t=5", at="2026-10-01")
        ev(g, "lease-renewal", at="2026-09-01")
        b = learning.retest(g, today="2026-10-10")
        self.assertEqual((b["concept"], b["due"], b["contrast"], b["overdue"]), ("lock-ttl", 2, "holder dies at t=5", 9))
        self.assertEqual([s["id"] for s in b["standards"]], ["predict-expiry"])
        ev(g, "lock-ttl", credit="scaffolded", at="2026-10-10")
        self.assertEqual(learning.retest(g, today="2026-10-10")["concept"], "lease-renewal")

    def test_system_scope(self):
        g = system_graph()
        ev(g, "bookmark-atomic", credit="handed", at="2026-10-01")       # due, but not in the locking system
        self.assertEqual(learning.retest(g, today="2026-10-10", system="locking"), {"due": 0})
        self.assertEqual(learning.retest(g, today="2026-10-10")["concept"], "bookmark-atomic")
        with self.assertRaises(learning.Invalid):
            learning.retest(g, system="nope")


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


class CLI(unittest.TestCase):
    def test_learn_roundtrip_on_a_scratch_graph(self):
        import subprocess
        learn = os.path.join(os.path.dirname(os.path.realpath(__file__)), "learn")
        with tempfile.TemporaryDirectory() as d:
            env = {**os.environ, "LEARNING_GRAPH": os.path.join(d, "g.json"), "LEARNING_MEMORY": "0"}

            def run(*args):
                r = subprocess.run([sys.executable, learn, *args], env=env, capture_output=True, text=True)
                self.assertEqual(r.returncode, 0, r.stderr)
                return r.stdout

            run("map", json.dumps({"topic": {"id": "t", "title": "T"}, "stages": [
                {"name": "s", "concepts": [{"id": "a", "analogs": ["b"]}, {"id": "c", "builds_on": ["a"]}]}]}))
            run("evidence", json.dumps({"concept": "b", "level": "explain", "at": "2026-01-01"}))
            run("evidence", json.dumps({"concept": "a", "level": "predict", "outcome": "miss",
                                        "confidence": "high", "contrast": "same, but X"}), "--topic", "t")
            run("restate", "b", "b in my words")
            self.assertEqual(json.loads(run("opener", "--topic", "t"))[0]["id"], "b")
            self.assertEqual(json.loads(run("transfers", "--topic", "t")), [{"concept": "a", "via": "b", "setting": ""}])
            self.assertEqual(json.loads(run("gaps", "--topic", "t")), [{"concept": "a", "blocks": "c"}])
            c = json.loads(run("concept", "a"))
            self.assertEqual((c["mastery"]["miss_confidence"], c["evidence"][0]["contrast"]), ("high", "same, but X"))
            state = run("state", "--topic", "t")
            self.assertIn("b in my words", state)
            self.assertIn("OPEN MISS (high confidence)", state)
            r = subprocess.run([sys.executable, learn, "evidence", '{"concept": "a", "level": "predict", "confidence": "sure"}'],
                               env=env, capture_output=True, text=True)
            self.assertEqual(r.returncode, 1)
            self.assertIn("confidence", r.stderr)
            run("system", json.dumps({"id": "sys", "title": "Sys", "standards": [{"id": "s1", "can_do": "do it", "concepts": ["a"]}]}))
            run("capture", json.dumps({"concepts": [{"id": "d", "standard": "s1"}],
                                       "evidence": [{"standard": "s1", "level": "explain", "credit": "scaffolded"}]}), "--session", "x")
            std = json.loads(run("standard", "s1"))
            self.assertEqual((std["concepts"], std["evidence"][0]["source"]), (["a", "d"], "chat"))
            self.assertIn("### Active system: Sys [sys]", run("state", "--system", "sys"))
            env["LEARNING_OFFERED"] = os.path.join(d, "offered")
            self.assertEqual(json.loads(run("retest", "--claim"))["concept"], "b")   # a was tested today
            r = subprocess.run([sys.executable, learn, "retest", "--claim"], env=env, capture_output=True, text=True)
            self.assertEqual(r.returncode, 3)
            nudge = subprocess.run([sys.executable, learn, "nudge"], env=env, input="{}", capture_output=True, text=True)
            self.assertEqual((nudge.returncode, nudge.stdout), (0, ""))   # offered today: silent


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
