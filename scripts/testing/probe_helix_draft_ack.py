"""Exercise the candidate Helix save acknowledgement against a real durable store."""
import argparse
import errno
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import signal
import sqlite3
import struct
import subprocess
import sys
import termios
import time

from helix_save_journal import Refused, SaveJournal


class Editor:
    def __init__(self, root, binary, runtime):
        self.root, self.terminal, self.exited = root, bytearray(), False
        projection_fd = os.open(root / "editor.lock", os.O_RDWR | os.O_NOFOLLOW)
        fcntl.flock(projection_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        os.set_inheritable(projection_fd, True)
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(root / "files")
            env = {**os.environ, "TERM": "xterm-256color", "COLORTERM": "truecolor", "HELIX_RUNTIME": str(runtime),
                   "HELIX_DRAFT_SAVE_REQUIRED": "1", "HELIX_DRAFT_LEASE_FD": str(projection_fd),
                   "XDG_CONFIG_HOME": str(root / "config"), "XDG_CACHE_HOME": str(root / "cache")}
            os.execve(binary, [str(binary), "--config", str(root / "config.toml"), "--log", str(root / "helix.log"), "-vvv", "main.probe"], env)
        os.close(projection_fd)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", 35, 120, 0, 0))

    def events(self, kind=None):
        path = self.root / "events.jsonl"
        rows = []
        for line in path.read_text().splitlines() if path.exists() else []:
            try:
                row = json.loads(line)
                if kind is None or row["event"] == kind:
                    rows.append(row)
            except json.JSONDecodeError:
                pass
        return rows

    def log(self):
        path = self.root / "helix.log"
        return path.read_text() if path.exists() else ""

    def pump(self):
        if not self.exited:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                self.exited = True
                self.exit_status = os.waitstatus_to_exitcode(status)
        readable, _, _ = select.select([self.fd], [], [], 0.02)
        if readable:
            try:
                data = os.read(self.fd, 65536)
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                data = b""
            self.terminal.extend(data)
            for query, reply in ((b"\x1b[6n", b"\x1b[1;1R"), (b"\x1b[c", b"\x1b[?1;2c"), (b"\x1b[>c", b"\x1b[>0;0;0c"), (b"\x1b[?u", b"\x1b[?0u")):
                if query in data:
                    os.write(self.fd, reply)

    def wait(self, condition, label, timeout=15):
        deadline = time.monotonic() + timeout
        while not condition():
            self.pump()
            if time.monotonic() > deadline:
                raise AssertionError(label + "; log tail=" + self.log()[-1800:])

    def send(self, keys):
        os.write(self.fd, keys)

    def edit(self, content):
        self.send(b"%c" + content.encode() + b"\x1b")
        emitted_text = json.dumps({"text": content + "\n"}, separators=(",", ":"))[1:-1]
        self.wait(lambda: emitted_text in self.log() or any(content in x["params"]["contentChanges"][-1]["text"] for x in self.events("changed")), "buffer change")

    def finish(self):
        if not self.exited:
            os.kill(self.pid, signal.SIGTERM)
            os.waitpid(self.pid, 0)
        os.close(self.fd)
        (self.root / "terminal.bin").write_bytes(self.terminal)


def journal_state(root):
    db = sqlite3.connect((root / "save.sqlite").as_uri() + "?mode=ro", uri=True)
    try:
        return db.execute("SELECT revision FROM state").fetchone()[0], db.execute("SELECT COUNT(*) FROM versions WHERE revision>0").fetchone()[0]
    finally:
        db.close()


def run_case(name, output, binary, runtime):
    root = output / name
    SaveJournal.create(root, "BEFORE\n", "disposable-snapshot", "fixture-owner")
    (root / "config/helix").mkdir(parents=True)
    (root / "config.toml").write_text("[editor]\ntrue-color=true\nauto-format=false\n")
    server = Path(__file__).with_name("helix_save_lsp.py")
    (root / "config/helix/languages.toml").write_text('[language-server.draft]\ncommand='+json.dumps(sys.executable)+'\nargs='+json.dumps([str(server),str(root),'fixture-owner'])+'\ntimeout=1\n\n[[language]]\nname="canopy-save-probe"\nscope="source.canopy-save-probe"\nfile-types=["probe"]\nlanguage-servers=["draft"]\nauto-format=false\n')
    for flag in {"write": ("hold-accept",), "write-quit": ("hold-accept",), "late-ack": ("hold-accept",),
                 "lost-response": ("drop-first-response",), "wrong-receipt": ("corrupt-response",),
                 "companion-crash": ("drop-first-response", "hold-successor"),
                 "unavailable": ("no-bridge",)}.get(name, ()):
        (root / flag).touch()
    editor = Editor(root, binary, runtime)
    try:
        editor.wait(lambda: editor.events("opened"), "language server ready")
        editor.edit("RAW")
        if name == "write-failure":
            (root / "files/main.probe").chmod(0o444)
        editor.send(b":write other.probe\r" if name == "path-change" else b":wq\r" if name in ("write-quit", "wrong-receipt", "unavailable", "write-failure") else b":write\r")
        if name in ("write", "write-quit", "late-ack"):
            editor.wait(lambda: editor.events("accept-request"), "save request at acceptance barrier")
            assert journal_state(root) == (0, 0)
            assert (root / "files/main.probe").read_text() == "RAW\n"
            assert not editor.events("saved") and not editor.exited
            if name == "late-ack":
                editor.edit("NEW")
            (root / "release-accept").touch()
        if name in ("lost-response", "companion-crash"):
            editor.wait(lambda: editor.events("response-dropped"), "committed response dropped")
            assert journal_state(root) == (1, 1)
            assert not editor.events("saved")
            editor.edit("NEW")
            editor.wait(lambda: "timed out" in editor.log(), "save timeout visible")
            editor.send(b":write\r")
            if name == "companion-crash":
                editor.wait(lambda: len(editor.events("accept-request")) == 3, "successor held after original replay")
                pid = editor.events("server-started")[0]["pid"]
                os.kill(pid, signal.SIGKILL)
                editor.wait(lambda: "StreamClosed" in editor.log() or "server closed the stream" in editor.log(), "companion failure visible")
                assert journal_state(root) == (1, 1)
                assert (root / "files/main.probe").read_text() == "NEW\n"
                try:
                    SaveJournal(root, "another-owner")
                except Refused:
                    pass
                else:
                    raise AssertionError("companion crash released the live editor's projection")
                editor.send(b":q!\r")
                editor.wait(lambda: editor.exited, "explicit abandoned-session exit")
                recovered = SaveJournal(root, "new-owner")
                try:
                    assert recovered.snapshot()[0] == b"RAW\n"
                    try:
                        recovered.ready()
                    except Refused:
                        pass
                    else:
                        raise AssertionError("ambiguous projection was silently reconciled")
                finally:
                    recovered.close()
                return {"case": name, "revision": 1, "accepted_records": 1, "exit_status": editor.exit_status,
                        "file": "NEW\n", "events": editor.events(), "recovery": "explicit reconciliation required"}
            editor.wait(lambda: editor.events("saved"), "recovered acceptance and next save")
            requests = [x["payload"] for x in editor.events("accept-request")]
            assert len(requests) == 3 and requests[0] == requests[1], requests
            assert requests[2]["expectedRevision"] == 1 and requests[2]["text"] == "NEW\n"
            assert journal_state(root) == (2, 2)
        elif name == "wrong-receipt":
            editor.wait(lambda: "acknowledgement does not match" in editor.log(), "wrong receipt refused")
            assert journal_state(root) == (1, 1)
            assert not editor.events("saved") and not editor.exited
            (root / "corrupt-response").unlink()
            editor.send(b":wq\r")
        elif name in ("unavailable", "path-change", "write-failure"):
            expected = "required draft save bridge" if name == "unavailable" else "does not allow changing" if name == "path-change" else "read only"
            editor.wait(lambda: expected in editor.log(), "unsupported save refused")
            assert journal_state(root) == (0, 0) and not editor.events("accept-request")
            assert (root / "files/main.probe").read_text() == "BEFORE\n"
            assert not (root / "files/other.probe").exists()
            assert not editor.exited
            (root / "files/main.probe").chmod(0o644)
            editor.send(b":q!\r")
        elif name != "write-quit":
            editor.wait(lambda: editor.events("saved"), "accepted save notification")
            assert journal_state(root) == (1, 1)
            if name == "late-ack":
                editor.send(b":q\r")
                editor.wait(lambda: "unsaved buffer" in editor.log(), "newer buffer stays dirty")
                assert not editor.exited
                editor.send(b":write\r")
                editor.wait(lambda: len(editor.events("saved")) == 2, "second buffer accepted")
                assert journal_state(root) == (2, 2)
            elif name == "write":
                editor.send(b":write\r")
                editor.wait(lambda: len(editor.events("saved")) == 2, "unchanged write reuses receipt")
                assert len(editor.events("accept-request")) == 2 and journal_state(root) == (1, 1)
        if name in ("write", "late-ack", "lost-response"):
            editor.send(b":q\r")
        editor.wait(lambda: editor.exited, "editor exit")
        assert editor.exit_status == 0
        revision, count = journal_state(root)
        return {"case": name, "revision": revision, "accepted_records": count, "exit_status": editor.exit_status,
                "events": editor.events(), "file": (root / "files/main.probe").read_text()}
    finally:
        editor.finish()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--show-job")
    args = parser.parse_args()
    args.output.mkdir()
    cases = ("write", "write-quit", "lost-response", "late-ack", "wrong-receipt", "unavailable", "path-change", "write-failure", "companion-crash")
    results = []
    try:
        for name in cases:
            result = run_case(name, args.output, args.binary.resolve(), args.runtime.resolve())
            results.append(result)
            print(json.dumps({k: v for k, v in result.items() if k != "events"}), flush=True)
            if args.show_job:
                subprocess.run([str(Path(__file__).parents[1] / "show-job"), "set", args.show_job,
                    "--title", "Helix durable-save candidate", "--row", "build 1/1 compiled", "--row",
                    f"editor checks {len(results)}/{len(cases)} {name}", "--line", "installed editor unchanged"], check=True)
    except BaseException:
        if args.show_job:
            subprocess.run([str(Path(__file__).parents[1] / "show-job"), "fail", args.show_job,
                            "--note", "candidate editor check failed"], check=True)
        raise
    (args.output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
