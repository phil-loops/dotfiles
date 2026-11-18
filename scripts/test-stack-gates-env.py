#!/usr/bin/env python3
"""stack-gates' environment words: a failing gate's summary opens with the line that names the
error, and a down database is named before the tests run."""
import importlib.machinery
import importlib.util
import os
import socket
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
loader = importlib.machinery.SourceFileLoader("stack_gates", os.path.join(HERE, "stack-gates"))
spec = importlib.util.spec_from_loader("stack_gates", loader)
gates = importlib.util.module_from_spec(spec)
loader.exec_module(gates)

failures = 0


def check(name, ok, detail=""):
    global failures
    print(("✓ " if ok else "✗ ") + name + ("" if ok else f" — {detail}"))
    failures += 0 if ok else 1


frames = "\n".join(f"    at Object.<anonymous> (/x/node_modules/@prisma/client/runtime/library.js:{i}:10)" for i in range(14))
out = "PrismaClientInitializationError: Can't reach database server at `localhost:5432`\n" + frames
s = gates.last_lines(out)
check("a Prisma failure's summary opens with the error line, not a frame", s.splitlines()[0].startswith("PrismaClientInitializationError"), s.splitlines()[:2])
check("…and still ends with the tail", s.splitlines()[-1].endswith(":13:10)"), s.splitlines()[-1])
check("a short failure is unchanged", gates.last_lines("error: boom\nmore") == "error: boom\nmore")

with tempfile.TemporaryDirectory() as d:
    check("no .env says nothing", gates.db_reachable(d) == ("", True))
    with open(os.path.join(d, ".env"), "w") as f:
        f.write("OTHER=1\n")
    check("no DATABASE_URL says nothing", gates.db_reachable(d) == ("", True))
    srv = socket.socket(); srv.bind(("127.0.0.1", 0)); port = srv.getsockname()[1]; srv.close()   # a port nobody listens on
    with open(os.path.join(d, ".env"), "w") as f:
        f.write(f'DATABASE_URL="postgresql://u:p@127.0.0.1:{port}/db?schema=public"\n')
    note, ok = gates.db_reachable(d, timeout=1.0)
    check("a down database is named with its host and port", not ok and f"127.0.0.1:{port}" in note and "Postgres is down" in note, note)
    srv = socket.socket(); srv.bind(("127.0.0.1", 0)); srv.listen(1); port = srv.getsockname()[1]
    with open(os.path.join(d, ".env"), "w") as f:
        f.write(f"DATABASE_URL=postgresql://u:p@127.0.0.1:{port}/db\n")
    check("a listening database passes", gates.db_reachable(d, timeout=1.0) == ("", True))
    srv.close()

with tempfile.TemporaryDirectory() as d:
    check("no CI task file: no services to check", gates.ci_services(d) == [] and gates.services_down(d) == [])
    live = socket.socket(); live.bind(("127.0.0.1", 0)); live.listen(); up_port = live.getsockname()[1]
    gone = socket.socket(); gone.bind(("127.0.0.1", 0)); down_port = gone.getsockname()[1]; gone.close()
    os.makedirs(os.path.join(d, "tasks", "ci"))
    with open(os.path.join(d, "tasks", "ci", "tasks.yml"), "w") as f:
        f.write(f"""tasks:
  test-prepare:
    cmds:
      - npx wait-on --timeout 10s tcp:localhost:5432
      - npx wait-on --timeout 10s tcp:localhost:{up_port}
      - npx wait-on --timeout 30s http://localhost:{down_port}/ping
  other:
    cmds:
      - npx wait-on --timeout 10s tcp:localhost:1
""")
    check("CI's test-prepare waits are the list, and nothing outside it",
          [p for _, p in gates.ci_services(d)] == [5432, up_port, down_port], gates.ci_services(d))
    check("a service nobody answers on is named; Postgres is left to its own check",
          gates.services_down(d) == [f"http://localhost:{down_port}/ping"], gates.services_down(d))
    live.close()

print(f"\n{'OK' if not failures else 'FAIL'} — {failures} failure(s)")
sys.exit(1 if failures else 0)
