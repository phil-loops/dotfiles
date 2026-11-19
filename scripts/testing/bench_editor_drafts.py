"""Compare experimental draft backends using disposable repositories only."""
import argparse
import json
import os
from pathlib import Path
import queue
import random
import shutil
import stat
import statistics
import subprocess
import sys
import threading
import time
import uuid

from editor_drafts import Draft, Objects, Refused, fixture

BACKENDS = ("workspace", "hybrid", "objects")


def prepare(root, backend, path):
    objects = Objects(root.parent / "repo")
    started = time.perf_counter()
    try:
        draft = Draft.create(root, objects, backend, "refs/canopy-lab/fixture")
        try:
            target = draft.project(path)
            (root / "entry.json").write_text(json.dumps({"path": path}))
            return {"backend": backend, "dir": str(root / "files"), "path": path, "file": str(target),
                    "prepareMs": (time.perf_counter() - started) * 1000}
        finally:
            draft.close()
    finally:
        objects.close()


def save(root):
    objects = Objects(root.parent / "repo")
    draft = Draft(root, objects)
    try:
        started = time.perf_counter()
        path = json.loads((root / "entry.json").read_text())["path"]
        target = draft.project(path)
        fd = os.open(target, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, "rb") as file:
            before = os.fstat(file.fileno())
            if not stat.S_ISREG(before.st_mode):
                raise Refused("the declared editor file is not regular")
            content = file.read()
            after = os.fstat(file.fileno())
            if (before.st_mtime_ns, before.st_ctime_ns, before.st_size) != (after.st_mtime_ns, after.st_ctime_ns, after.st_size):
                raise Refused("the editor file changed during capture")
        version = draft.mutate("editor-write", 0, {path: ("100755" if before.st_mode & 0o111 else "100644", content)})
        receipt = draft.publish("editor-save", version)
        elapsed = (time.perf_counter() - started) * 1000
        actual = objects.read(receipt["tree"], path)[1]
        return {**receipt, "saveCoreMs": elapsed, "text": actual.decode(), "count": int(objects.text("rev-list", "--count", draft.meta["base"] + ".." + draft.meta["ref"]))}
    finally:
        draft.close()
        objects.close()


def summarize(values):
    middle = statistics.median(values)
    return {"n": len(values), "medianMs": middle, "madMs": statistics.median(abs(value - middle) for value in values),
            "minMs": min(values), "maxMs": max(values)}


def benchmark(root, counts, samples, source):
    root.mkdir()
    results = []
    for count in counts:
        case = root / f"files-{count}"
        case.mkdir()
        objects = fixture(case / "repo", count, source)
        total = len(objects.run("ls-tree", "-r", "--name-only", "-z", "refs/canopy-lab/fixture").split(b"\0")) - 1
        path = "payload/0000/000000.txt" if count else "edit.txt"
        order = []
        for pair in range(samples):
            batch = list(BACKENDS)
            random.Random(7183 + pair).shuffle(batch)
            order.extend(batch)
        for number, mode in enumerate(order):
            objects.close()
            objects.cache.clear()
            objects.calls.clear()
            objects.reads.clear()
            trial = case / uuid.uuid4().hex
            started = time.perf_counter()
            draft = Draft.create(trial, objects, mode, "refs/canopy-lab/fixture")
            target = draft.project(path)
            open_ms = (time.perf_counter() - started) * 1000
            changed = f"after trial {number}\n".encode()
            started = time.perf_counter()
            target.write_bytes(changed)
            draft.mutate("write", 0, {path: ("100644", changed)})
            receipt = draft.publish("save", 1)
            save_ms = (time.perf_counter() - started) * 1000
            calls = list(objects.calls)
            reads = list(objects.reads)
            if objects.read(receipt["tree"], path)[1] != changed:
                raise AssertionError("the published bytes differ")
            results.append({"files": total, "backend": mode, "order": number, "openMs": open_ms, "saveMs": save_ms,
                            "materializedFiles": 1 if mode == "objects" else total,
                            "indexCommands": sum(call[0] in ("read-tree", "update-index", "write-tree") for call in calls),
                            "filesystemScans": sum(call[0] in ("status", "add", "diff-files") for call in calls),
                            "objectReads": len(reads), "objectBytes": sum(size for _, size in reads)})
            print(f"{total} files {number + 1}/{len(order)} {mode}: open {open_ms:.1f} ms, publish {save_ms:.1f} ms", file=sys.stderr, flush=True)
            if mode != "objects":
                objects.run("worktree", "remove", "--force", str(trial / "files"))
            draft.close()
            shutil.rmtree(trial)
        objects.close()
    groups = []
    for files in sorted({row["files"] for row in results}):
        for mode in BACKENDS:
            subset = [row for row in results if row["files"] == files and row["backend"] == mode]
            groups.append({"files": files, "backend": mode, "open": summarize([row["openMs"] for row in subset]),
                           "save": summarize([row["saveMs"] for row in subset])})
    report = {"source": str(source) if source else "synthetic", "osCachesFlushed": False,
              "gitVersion": subprocess.check_output(["git", "--version"], text=True).strip(), "groups": groups, "samples": results}
    (root / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    return {"report": str(root / "results.json"), "groups": groups}


def definition(binary, directory, document):
    messages = queue.Queue()
    process = subprocess.Popen([str(binary), "--lsp", "--stdio"], cwd=directory, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, env={**os.environ, "GOMEMLIMIT": "512MiB"})
    def reader():
        try:
            while True:
                length = None
                while line := process.stdout.readline():
                    if line in (b"\r\n", b"\n"):
                        break
                    if line.lower().startswith(b"content-length:"):
                        length = int(line.split(b":", 1)[1])
                if length is None:
                    return
                messages.put(json.loads(process.stdout.read(length)))
        finally:
            messages.put(None)
    worker = threading.Thread(target=reader, daemon=True)
    worker.start()
    def send(method, params, number=None):
        body = {"jsonrpc": "2.0", "method": method, "params": params}
        if number is not None:
            body["id"] = number
        encoded = json.dumps(body).encode()
        process.stdin.write(f"Content-Length: {len(encoded)}\r\n\r\n".encode() + encoded)
        process.stdin.flush()
    def answer(number):
        until = time.monotonic() + 15
        while True:
            message = messages.get(timeout=max(0.01, until - time.monotonic()))
            if message is None:
                raise Refused("the isolated language server stopped")
            if message.get("id") == number and "method" not in message:
                if "error" in message:
                    raise Refused(str(message["error"]))
                return message.get("result")
            if "id" in message and "method" in message:
                reply = json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": [None] * len(message.get("params", {}).get("items", []))
                                    if message["method"] == "workspace/configuration" else None}).encode()
                process.stdin.write(f"Content-Length: {len(reply)}\r\n\r\n".encode() + reply)
                process.stdin.flush()
            if time.monotonic() >= until:
                raise Refused("the isolated language server timed out")
    started = time.perf_counter()
    try:
        send("initialize", {"processId": os.getpid(), "rootUri": directory.as_uri(),
                            "capabilities": {"textDocument": {"definition": {"linkSupport": True}},
                                             "workspace": {"didChangeWatchedFiles": {"dynamicRegistration": True}}}}, 1)
        answer(1)
        send("initialized", {})
        text = document.read_text()
        send("textDocument/didOpen", {"textDocument": {"uri": document.as_uri(), "languageId": "typescript", "version": 1, "text": text}})
        send("textDocument/definition", {"textDocument": {"uri": document.as_uri()},
                                         "position": {"line": 1, "character": text.splitlines()[1].index("value") + 1}}, 2)
        locations = answer(2) or []
        if isinstance(locations, dict):
            locations = [locations]
        targets = [location.get("targetUri") or location.get("uri") for location in locations]
        return {"definitionFound": any(target and target.endswith("/helper.ts") for target in targets), "targets": targets,
                "ms": (time.perf_counter() - started) * 1000}
    finally:
        if process.poll() is None:
            process.terminate()
        process.wait(timeout=5)
        process.stdin.close()
        worker.join(timeout=2)
        process.stdout.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    create = commands.add_parser("fixture")
    create.add_argument("root", type=Path)
    create.add_argument("--files", type=int, default=1000)
    create.add_argument("--source", type=Path)
    opening = commands.add_parser("open")
    opening.add_argument("root", type=Path)
    opening.add_argument("backend", choices=BACKENDS)
    opening.add_argument("--path", default="edit.txt")
    saving = commands.add_parser("save")
    saving.add_argument("root", type=Path)
    bench = commands.add_parser("bench")
    bench.add_argument("root", type=Path)
    bench.add_argument("--files", type=int, nargs="+", default=[1000, 10000, 100000])
    bench.add_argument("--samples", type=int, default=12)
    bench.add_argument("--source", type=Path)
    probe = commands.add_parser("probe")
    probe.add_argument("root", type=Path)
    probe.add_argument("binary", type=Path)
    args = parser.parse_args()
    args.root = args.root.resolve()
    if args.command == "fixture":
        args.root.mkdir()
        objects = fixture(args.root / "repo", args.files, args.source)
        objects.close()
        result = {"ok": True}
    elif args.command == "open":
        result = prepare(args.root, args.backend, args.path)
    elif args.command == "save":
        result = save(args.root)
    elif args.command == "bench":
        result = benchmark(args.root, args.files, args.samples, args.source)
    else:
        objects = Objects(args.root / "repo")
        result = {}
        for mode in BACKENDS:
            draft = Draft.create(args.root / uuid.uuid4().hex, objects, mode, "refs/canopy-lab/fixture")
            try:
                main_file = draft.project("canopy-lab/main.ts")
                draft.project("canopy-lab/tsconfig.json")
                result[mode] = {**definition(args.binary.resolve(), main_file.parent, main_file),
                                "snapshotImport": draft.read("canopy-lab/helper.ts")[1].decode(),
                                "importOnDisk": main_file.with_name("helper.ts").exists()}
            finally:
                draft.close()
        objects.close()
    print(json.dumps(result))


if __name__ == "__main__":
    main()
