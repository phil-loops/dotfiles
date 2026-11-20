"""Expose the disposable accepted-save journal to the opt-in Helix candidate."""
import json
import os
from pathlib import Path
import sys
import time

from helix_save_journal import Refused, SaveJournal


def send(message):
    data = json.dumps(message).encode()
    sys.stdout.buffer.write(b"Content-Length: " + str(len(data)).encode() + b"\r\n\r\n" + data)
    sys.stdout.buffer.flush()


def record(root, event, **values):
    with (root / "events.jsonl").open("a") as stream:
        stream.write(json.dumps({"event": event, **values}) + "\n")


def wait_gate(path):
    deadline = time.monotonic() + 30
    while not path.exists():
        if time.monotonic() > deadline:
            raise Refused("test acceptance gate timed out")
        time.sleep(0.01)


def main(root, generation):
    journal = SaveJournal(root, generation, projection_fd=int(os.environ["HELIX_DRAFT_LEASE_FD"]))
    record(root, "server-started", pid=os.getpid())
    try:
        while True:
            headers = {}
            while True:
                line = sys.stdin.buffer.readline()
                if not line:
                    return
                if line == b"\r\n":
                    break
                key, value = line.decode().split(":", 1)
                headers[key.lower()] = value.strip()
            message = json.loads(sys.stdin.buffer.read(int(headers["content-length"])))
            method, params = message.get("method"), message.get("params", {})
            result = None
            try:
                if method == "initialize":
                    capability = journal.ready()
                    result = {"capabilities": {"textDocumentSync": {"openClose": True, "change": 1, "save": {"includeText": True}},
                                               "experimental": {"canopyDraftSave": capability}}}
                    if (root / "no-bridge").exists():
                        result["capabilities"].pop("experimental")
                elif method == "canopy/draft/acceptSave":
                    record(root, "accept-request", payload=params)
                    if (root / "hold-successor").exists() and params["expectedRevision"] == 1:
                        wait_gate(root / "release-successor")
                    if (root / "hold-accept").exists():
                        wait_gate(root / "release-accept")
                    result = journal.accept(params)
                    record(root, "accepted", receipt=result)
                    if (root / "drop-first-response").exists():
                        (root / "drop-first-response").unlink()
                        record(root, "response-dropped")
                        continue
                    if (root / "corrupt-response").exists():
                        result = {**result, "acceptedText": "wrong bytes"}
                    record(root, "response", receipt=result)
                elif method == "textDocument/didOpen":
                    record(root, "opened", params=params)
                elif method == "textDocument/didChange":
                    record(root, "changed", params=params)
                elif method == "textDocument/didSave":
                    record(root, "saved", params=params)
                elif method == "shutdown":
                    record(root, "shutdown")
                elif method == "exit":
                    return
                if "id" in message:
                    send({"jsonrpc": "2.0", "id": message["id"], "result": result})
            except (Refused, ValueError, KeyError) as error:
                record(root, "refused", reason=str(error))
                if "id" in message:
                    send({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32001, "message": str(error) + "; payload preserved; explicit recovery required"}})
    finally:
        journal.close()


if __name__ == "__main__":
    main(Path(sys.argv[1]), sys.argv[2])
