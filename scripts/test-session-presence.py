#!/usr/bin/env python3
"""Presence is per conversation (DESIGN.md round 27, principle 5): a subagent's tool calls land on
its parent's record, a new conversation in the same process (/clear, /resume) ends the previous
one, and a record whose process is gone is reaped."""
import json
import os
import subprocess
import sys
import tempfile
import unittest

HOOK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "claude-session-track")


class Presence(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()

    def hook(self, event, sid, **extra):
        payload = {"hook_event_name": event, "session_id": sid, "cwd": self.dir, **extra}
        env = dict(os.environ, CLAUDE_SESSION_PRESENCE_DIR=self.dir)
        subprocess.run([sys.executable, HOOK], input=json.dumps(payload), text=True, env=env, check=True)

    def records(self):
        return sorted(f[:-5] for f in os.listdir(self.dir) if f.endswith(".json"))

    def test_a_subagents_calls_land_on_its_parents_record(self):
        self.hook("SessionStart", "parent")
        self.hook("PostToolUse", "parent", agent_id="child", tool_name="Bash", tool_input={})
        self.assertEqual(self.records(), ["parent"])

    def test_a_new_conversation_in_the_process_ends_the_previous_one(self):
        self.hook("SessionStart", "before-clear")
        self.hook("SessionStart", "after-clear")
        self.assertEqual(self.records(), ["after-clear"])

    def test_a_record_whose_process_is_gone_is_reaped(self):
        with open(os.path.join(self.dir, "gone.json"), "w") as f:
            json.dump({"session_id": "gone", "pid": 999999, "start_time": "never", "last_active": 0}, f)
        self.hook("SessionStart", "here")
        self.assertEqual(self.records(), ["here"])


    def test_an_edit_records_the_branch_of_the_worktree_it_landed_in(self):
        repo = os.path.join(self.dir, "proj")
        git = lambda *a: subprocess.run(["git", "-C", repo, *a], check=True, capture_output=True)
        subprocess.run(["git", "init", "-q", "-b", "main", repo], check=True)
        git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "root")
        git("worktree", "add", "-q", "-b", "feat/x", os.path.join(self.dir, "proj-wt"))
        edited = os.path.join(self.dir, "proj-wt", "new", "file.ts")
        self.hook("PostToolUse", "chat", tool_name="Edit", tool_input={"file_path": edited})
        with open(os.path.join(self.dir, "chat.json")) as f:
            acted = json.load(f).get("acted", {})
        self.assertEqual(list(acted), ["proj:feat/x"], "named by its main worktree, as the viewer names repos")
        git("config", "branch.feat/x.stack-work", "w_feat")
        link = os.path.join(self.dir, "link.ts")
        os.symlink(edited, link)
        self.hook("PostToolUse", "chat", tool_name="Write", tool_input={"file_path": link})
        with open(os.path.join(self.dir, "chat.json")) as f:
            self.assertEqual(json.load(f)["acted"]["proj:feat/x"].get("work"), "w_feat",
                             "a symlink resolves to the worktree it points into, and the branch's work id rides along")
        git("-C", os.path.join(self.dir, "proj-wt"), "checkout", "-q", "--detach")
        self.hook("PostToolUse", "chat", tool_name="Edit", tool_input={"file_path": edited})
        self.hook("PostToolUse", "chat", tool_name="Bash", tool_input={})
        with open(os.path.join(self.dir, "chat.json")) as f:
            self.assertEqual(list(json.load(f).get("acted", {})), ["proj:feat/x"], "a detached worktree or a Bash call records nothing")


    def test_concurrent_hooks_keep_every_edit(self):
        repos = []
        for n in range(6):
            repo = os.path.join(self.dir, f"r{n}")
            subprocess.run(["git", "init", "-q", "-b", f"b{n}", repo], check=True)
            subprocess.run(["git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "root"], check=True)
            repos.append(os.path.join(repo, "f.ts"))
        env = dict(os.environ, CLAUDE_SESSION_PRESENCE_DIR=self.dir)
        procs = [subprocess.Popen([sys.executable, HOOK], stdin=subprocess.PIPE, text=True, env=env) for _ in repos]
        for p, f in zip(procs, repos):
            p.stdin.write(json.dumps({"hook_event_name": "PostToolUse", "session_id": "shared", "cwd": self.dir,
                                      "tool_name": "Edit", "tool_input": {"file_path": f}}))
            p.stdin.close()
        for p in procs:
            p.wait()
        with open(os.path.join(self.dir, "shared.json")) as f:
            self.assertEqual(sorted(json.load(f)["acted"]), [f"r{n}:b{n}" for n in range(6)], "a parent and its subagents writing at once lose nothing")


if __name__ == "__main__":
    unittest.main()
